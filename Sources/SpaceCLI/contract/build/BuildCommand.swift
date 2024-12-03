import Foundation
import Workspace
import Basics
import ArgumentParser

struct BuildCommandOptions: ParsableArguments {
    @Option(help: "The contract's name to build.")
    var contract: String? = nil
    
    @Option(help: "The path to a custom swift toolchain.")
    var customSwiftToolchain: String? = nil
}

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build a contract to a .wasm file"
    )
    
    @OptionGroup var options: BuildCommandOptions
    
    mutating func run() async throws {
        try await buildContract(
            contractName: self.options.contract,
            customSwiftToolchain: self.options.customSwiftToolchain
        )
    }
}

func buildContract(
    contractName: String?,
    customSwiftToolchain: String?
) async throws(CLIError) {
    guard try isValidProject() else {
        throw .common(.invalidProject)
    }
    
    let allContracts = try getAllContractsNames()
    
    let target: String
    if let contractName = contractName {
        target = contractName
    } else {
        guard allContracts.count == 1 else {
            throw .contractBuild(.multipleContractsFound(contracts: allContracts))
        }
        
        target = allContracts[0]
    }
    
    let fileManager = FileManager.default
    let pwd = fileManager.currentDirectoryPath
    let destVolumePath = "/app"
    
    let wasmPackageInfo = (try await generateWASMPackage(sourcePackagePath: pwd, target: target))
    
    let buildFolder = "\(destVolumePath)/.space/sc-build"
    let buildFolderUrl = URL(fileURLWithPath: buildFolder, isDirectory: true)
    let sourceTargetPath = "\(destVolumePath)/Contracts/\(target)"
    let contractsUrl = buildFolderUrl.appending(path: "Contracts")
    let linkedTargetUrl = contractsUrl
        .appending(path: target)
    
    let objectFilePath = "\(buildFolder)/\(target).o"
    let wasmBuiltFilePath = "\(buildFolder)/\(target).wasm"
    let wasmOptFilePath = "\(buildFolder)/\(target)-opt.wasm"
    let targetPackageOutputPath = "\(destVolumePath)/Contracts/\(target)/Output"
    let wasmDestFilePath = "\(targetPackageOutputPath)/\(target).wasm"
    let wasmHostFinalPath = wasmDestFilePath.replacingOccurrences(of: destVolumePath, with: pwd)

    let swiftCommand = "/usr/bin/swift"

    do {
        // Explanations: we want to create a symbolic link of the source files before compiling them.
        // By doing so, we avoid generating *.o files in the user project root directory
        
        let newPackagePath = "\(buildFolder)/Package.swift"
        
        let newPackageBase64String = wasmPackageInfo.generatedPackage.toBase64()
        
        let rmContractsCommand = "rm -rf \(contractsUrl.path)"
        let createContractsCommand = "mkdir -p \(contractsUrl.path)"
        let rmOldGeneratedPackage = "rm -f \(newPackagePath)"
        let echoNewPackageCommand = """
            echo "\(newPackageBase64String)" | base64 --decode > \(newPackagePath)
        """
        let createOutputDirectoryCommand = "mkdir -p \(targetPackageOutputPath)"
        
        // Create the Contracts/TARGET symbolic link
        let symbolicTargetLinkCommand = "ln -sf \(sourceTargetPath) \(linkedTargetUrl.path)"
        
        let swiftBuildArguments: [String] = [
            "--package-path", buildFolder,
            "--target", target,
            "--triple", "wasm32-unknown-none-wasm",
            "--disable-index-store",
            "-Xswiftc", "-Osize",
            "-Xswiftc", "-gnone"
        ]
        let swiftBuildCommand = "SWIFT_WASM=true \(swiftCommand) build \(swiftBuildArguments.joined(separator: " "))"
        
        let wasmLdArguments = [
            "--no-entry", "--allow-undefined",
            "-o", wasmBuiltFilePath,
            objectFilePath,
            "objects/memcpy.o",
            "objects/init.o",
            "objects/libclang_rt.builtins-wasm32.a"
        ]
        let wasmLdCommand = "wasm-ld \(wasmLdArguments.joined(separator: " "))"
        
        let wasmOptCommand = "wasm-opt -Os -o \(wasmOptFilePath) \(wasmBuiltFilePath)"
        
        let oldWasmRmCommand = "rm -f \(wasmDestFilePath)"
        let copyWasmCommand = "cp \(wasmOptFilePath) \(wasmDestFilePath)"
        
        let _ = try await runInDocker(
            volumeURLs: (
                host: URL(fileURLWithPath: pwd, isDirectory: true),
                dest: URL(fileURLWithPath: destVolumePath, isDirectory: true)
            ),
            commands: [
                rmContractsCommand,
                createContractsCommand,
                rmOldGeneratedPackage,
                echoNewPackageCommand,
                createOutputDirectoryCommand,
                symbolicTargetLinkCommand,
                swiftBuildCommand,
                wasmLdCommand,
                wasmOptCommand,
                oldWasmRmCommand,
                copyWasmCommand
            ]
        )
        
        print(
            """
            \(target) built successfully!
            WASM output: \(wasmHostFinalPath)
            """
        )
    } catch {
        print("error: \(error)")
    }
}

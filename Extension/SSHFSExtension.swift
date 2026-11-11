import ExtensionFoundation
import Foundation
import FSKit

@main
struct SSHFSExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        SSHFileSystem()
    }
}

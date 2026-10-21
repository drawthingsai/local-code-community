import ArgumentParser
import Darwin
import DrawThingsCLICommand
import Foundation
import HTML2VideoCommand
import HyperFramesCommand
import LeanCommand
import Z3Command
import ios_system

private let embeddedCommandRegistration: Result<Void, Error> = Result {
  if ios_registerCommand("hyperframes", hyperframes_main) == 0 {
    throw ValidationError("Unable to register the HyperFrames command.")
  }
  if ios_registerCommand("html2video", html2video_main) == 0 {
    throw ValidationError("Unable to register the html2video command.")
  }
  if ios_registerCommand("draw-things-cli", draw_things_main) == 0 {
    throw ValidationError("Unable to register the Draw Things CLI command.")
  }
  if ios_registerCommand("z3", z3_main) == 0 {
    throw ValidationError("Unable to register the Z3 command.")
  }
  if ios_registerCommand("lean", lean_main) == 0
    || ios_registerCommand("check_lean", check_lean_main) == 0
  {
    throw ValidationError("Unable to register the Lean commands.")
  }
}

func configureEmbeddedCommandEnvironment() throws -> URL {
  RemoteCredentialStore.prepareForEmbeddedCommands()
  numPythonInterpreters = 1
  ios_setStreams(stdin, stdout, stderr)

  let candidates = [
    Bundle.main.resourceURL?.appendingPathComponent("Library", isDirectory: true),
    Resources.repositoryURL?.appendingPathComponent(
      "Vendors/PythonIOS/ResourcesMacOS/Library", isDirectory: true),
  ].compactMap { $0 }
  guard
    let pythonHome = candidates.first(where: {
      FileManager.default.fileExists(
        atPath: $0.appendingPathComponent("lib/python3.14", isDirectory: true).path)
    })
  else {
    throw ValidationError(
      "Could not locate the embedded Python resources. Run through Bazel from the repository workspace."
    )
  }
  setenv("PYTHONHOME", pythonHome.path, 1)
  setenv("PYTHONUSERBASE", pythonHome.path, 1)
  let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "LocalCodeCLI", isDirectory: true)
  let pycache = cacheRoot.appendingPathComponent("pycache", isDirectory: true)
  let pipCache = cacheRoot.appendingPathComponent("pip-cache", isDirectory: true)
  try FileManager.default.createDirectory(at: pycache, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: pipCache, withIntermediateDirectories: true)
  setenv("PYTHONPYCACHEPREFIX", pycache.path, 1)
  setenv("PIP_CACHE_DIR", pipCache.path, 1)
  setenv("PIP_DISABLE_PIP_VERSION_CHECK", "1", 1)
  let certificate = pythonHome.appendingPathComponent(
    "lib/python3.14/site-packages/certifi/cacert.pem")
  if FileManager.default.fileExists(atPath: certificate.path) {
    setenv("SSL_CERT_FILE", certificate.path, 1)
  }
  if let resourceURL = Resources.resourceURL {
    let preload = resourceURL.appendingPathComponent(
      "NodeMobile/Runtime/virtual-node-child-preload.cjs")
    if FileManager.default.fileExists(atPath: preload.path) {
      setenv("NODE_MOBILE_VIRTUAL_NODE_PRELOAD", preload.path, 1)
    }
    let archive = Resources.nodeCommandArchiveURL
    let commands = try NodeMobileCommandResources.prepare(in: cacheRoot, archiveURL: archive)
    guard ios_setNodeCommandPaths(commands.npm.path, commands.npx.path) != 0 else {
      throw ValidationError("Could not configure bundled npm and npx commands.")
    }
  }
  let officeCandidates = [
    Bundle.main.resourceURL?.appendingPathComponent("office/Frameworks"),
    Resources.repositoryURL?.appendingPathComponent(
      "Vendors/LibreOffice/ResourcesMacOS/office/Frameworks"),
  ].compactMap { $0 }
  if let office = officeCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
  {
    guard ios_setOfficeProgramPath(office.path) != 0 else {
      throw ValidationError("Could not configure the office program resources.")
    }
  }
  initializeEnvironment()
  try embeddedCommandRegistration.get()
  return pythonHome
}

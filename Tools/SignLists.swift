// Signs the block lists the app downloads, so that it takes nothing it can't
// trace back to the key only its maintainer holds.
//
//   SignLists keygen <key>                 a new Ed25519 key; prints the public
//                                          half for Shield.swift
//   SignLists manifest <dir> <version> <key>
//                                          lists.json (every *.json.lzfse in
//                                          <dir> with its SHA-256 and size) and
//                                          lists.json.sig, its signature
//
// The private key never goes near the repository (publish-lists.sh keeps it in
// ~/.config/basicshell/).

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "keygen" where args.count == 3:
    let file = URL(fileURLWithPath: args[2])
    guard !FileManager.default.fileExists(atPath: file.path) else { fail("\(file.path) already exists") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "manifest" where args.count == 5:
    let dir = URL(fileURLWithPath: args[2])
    guard let text = try? String(contentsOfFile: args[4], encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("can't read the key at \(args[4])") }
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json.lzfse") }.sorted()
    guard !names.isEmpty else { fail("no .json.lzfse files in \(dir.path)") }
    let files: [[String: Any]] = try names.map { name in
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ["name": name, "sha256": hash, "size": data.count]
    }
    let manifest = try JSONSerialization.data(withJSONObject: ["version": args[3], "files": files], options: [.sortedKeys, .prettyPrinted])
    try manifest.write(to: dir.appendingPathComponent("lists.json"))
    try key.signature(for: manifest).write(to: dir.appendingPathComponent("lists.json.sig"))
    print("lists.json: version \(args[3]), \(names.joined(separator: ", "))")

default:
    fail("usage: SignLists keygen <key> | SignLists manifest <dir> <version> <key>")
}

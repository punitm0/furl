#!/usr/bin/env swift
// Ed25519 signing for Furl releases. The app installs an update by itself only when Furl.dmg.sig
// verifies against `UpdateConfig.signingPublicKey` (Sources/Furl/Services/UpdateInstaller.swift).
//
//   swift scripts/sign_update.swift generate          # once: make the key, print the public key
//   swift scripts/sign_update.swift public            # print the public key again
//   swift scripts/sign_update.swift sign build/Furl.dmg   # print the base64 signature
//
// The private key lives outside the repo, at $FURL_UPDATE_KEY or ~/.furl/update-signing-key (0600).
// Back it up somewhere safe: losing it means shipped apps can no longer install updates by themselves
// (they fall back to the Download button), and anyone who has it can sign an update.
import CryptoKit
import Foundation

let keyPath = ProcessInfo.processInfo.environment["FURL_UPDATE_KEY"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".furl/update-signing-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyPath). Run: swift scripts/sign_update.swift generate") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if FileManager.default.fileExists(atPath: keyPath) { fail("A key already exists at \(keyPath); not overwriting it.") }
    let key = Curve25519.Signing.PrivateKey()
    let dir = (keyPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard FileManager.default.createFile(atPath: keyPath, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600])
    else { fail("Couldn't write \(keyPath)") }
    print("Saved the private key to \(keyPath). Back it up.")
    print("Public key (paste into UpdateConfig.signingPublicKey):")
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first else { fail("Usage: sign <file>") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("Can't read \(path)") }
    let key = loadKey()
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("Signature didn't verify") }
    print(signature.base64EncodedString())
default:
    fail("Usage: sign_update.swift generate | public | sign <file>")
}

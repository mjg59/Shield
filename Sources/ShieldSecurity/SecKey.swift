//
//  SecKey.swift
//  Shield
//
//  Copyright © 2019 Outfox, inc.
//
//
//  Distributed under the MIT License, See LICENSE for details.
//

import Foundation
import ShieldCrypto


public enum SecKeyError: Int, Error {

  case queryFailed
  case decryptionFailed
  case encryptionFailed
  case signFailed
  case verifyFailed
  case importFailed
  case exportFailed
  case saveFailed
  case saveDuplicate
  case deleteFailed

  public static func build(error: SecKeyError, message: String, status: OSStatus) -> NSError {
    let error = error as NSError
    return NSError(domain: error.domain, code: error.code, userInfo: [NSLocalizedDescriptionKey: message, "status": Int(status) as NSNumber])
  }

  public var status: OSStatus? {
    return (self as NSError).userInfo["status"] as? OSStatus
  }

}


public enum SecEncryptionPadding {
  case pkcs1
  case oaep
  case none
}


private let maxSignatureBufferLen = 512


public extension SecKey {

  func persistentReference() throws -> Data {

    let query: [String: Any] = [
      kSecValueRef as String: self,
      kSecReturnPersistentRef as String: kCFBooleanTrue!,
    ]

    var ref: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &ref)
    if status != errSecSuccess {
      throw SecKeyError.build(error: .queryFailed, message: "Unable to locate transient reference", status: status)
    }
    return ref as! Data
  }

  static func load(persistentReference pref: Data) throws -> SecKey {

    let query: [String: Any] = [
      kSecValuePersistentRef as String: pref,
      kSecReturnRef as String: kCFBooleanTrue!,
    ]

    var ref: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &ref)
    if status != errSecSuccess {
      throw SecKeyError.build(error: .queryFailed, message: "Unable to locate persistent reference", status: status)
    }
    return ref as! SecKey
  }

  static func decode(fromData data: Data, type: CFString, class keyClass: CFString) throws -> SecKey {
    
    let attrs = [
      kSecClass as String: kSecClassKey,
      kSecAttrKeyClass as String: keyClass,
      kSecAttrKeyType as String: type,
      ] as CFDictionary
    
    var error: Unmanaged<CFError>?
    
    guard let key = SecKeyCreateWithData(data as CFData, attrs, &error), error == nil else {
      throw error!.takeRetainedValue()
    }
    
    return key
  }

  func encode() throws -> Data {

    var error: Unmanaged<CFError>?
    
    guard let data = SecKeyCopyExternalRepresentation(self, &error) else {
      throw error!.takeRetainedValue()
    }
    
    return data as Data
  }

  func attributes() throws -> [String: Any] {

    return SecKeyCopyAttributes(self) as! [String: Any]
  }

  func keyType() throws -> SecKeyType {
    let secType = try self.type() as CFString
    guard let type = SecKeyType(systemValue: secType) else {
      fatalError("Unsupported key type")
    }
    return type
  }

  func type() throws -> String {

    let attrs = try attributes()

    // iOS 10 SecKeyCopyAttributes returns string values, SecItemCopyMatching returns number values
    return (attrs[kSecAttrKeyType as String] as? NSNumber)?.stringValue ?? (attrs[kSecAttrKeyType as String] as! String)
  }

  func save() throws {
    
    let attrs = try attributes()

    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrKeyClass as String: attrs[kSecAttrKeyClass as String]!,
      kSecValueRef as String: self,
    ]

    let status = SecItemAdd(query as CFDictionary, nil)

    if status == errSecDuplicateItem {
      throw SecKeyError.saveDuplicate
    }
    else if status != errSecSuccess {
      throw SecKeyError.build(error: .saveFailed, message: "Item add failed", status: status)
    }

  }

  func delete() throws {

    try SecKey.delete(persistentReference: try persistentReference())
  }

  static func delete(persistentReference ref: Data) throws {

    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecValuePersistentRef as String: ref,
    ]

    let status = SecItemDelete(query as CFDictionary)
    if status != errSecSuccess {
      throw SecKeyError.deleteFailed
    }
  }

  func encrypt(plainText: Data, padding: SecEncryptionPadding) throws -> Data {

    #if os(iOS) || os(watchOS) || os(tvOS)

      var cipherText = Data(count: SecKeyGetBlockSize(self))
      var cipherTextLen = cipherText.count
      let status =
        plainText.withUnsafeBytes { plainTextPtr in
          cipherText.withUnsafeMutableBytes { cipherTextPtr in
            SecKeyEncrypt(self,
                          padding == .oaep ? .OAEP : .PKCS1,
                          plainTextPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          plainTextPtr.count,
                          cipherTextPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          &cipherTextLen)
          }
        }

      if status != errSecSuccess {
        throw SecKeyError.build(error: .encryptionFailed, message: "Encryption failed", status: status)
      }

      return cipherText.subdata(in: 0 ..< cipherTextLen)

    #elseif os(macOS)

      // To ensure compatibility with iOS version above
      if plainText.count > SecKeyGetBlockSize(self) {
        throw SecKeyError.encryptionFailed
      }

      var error: Unmanaged<CFError>?

      let transform = SecEncryptTransformCreate(self, &error)
      if error != nil {
        throw error!.takeRetainedValue()
      }

      if !SecTransformSetAttribute(transform, kSecPaddingKey, padding == .oaep ? kSecPaddingOAEPKey : kSecPaddingPKCS1Key, &error) {
        throw error!.takeRetainedValue()
      }

      if !SecTransformSetAttribute(transform, kSecTransformInputAttributeName, plainText as CFData, &error) {
        throw error!.takeRetainedValue()
      }

      let cipherText: CFTypeRef? = SecTransformExecute(transform, &error)
      if cipherText == nil {
        throw error!.takeRetainedValue()
      }

      return cipherText as! Data

    #endif
  }

  func decrypt(cipherText: Data, padding: SecEncryptionPadding) throws -> Data {

    #if os(iOS) || os(watchOS) || os(tvOS)

      var plainText = Data(count: SecKeyGetBlockSize(self))
      var plainTextLen = plainText.count
      let status =
        cipherText.withUnsafeBytes { cipherTextPtr in
          plainText.withUnsafeMutableBytes { plainTextPtr in
            SecKeyDecrypt(self,
                          padding == .oaep ? .OAEP : .PKCS1,
                          cipherTextPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          cipherTextPtr.count,
                          plainTextPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          &plainTextLen)
          }
        }

      if status != errSecSuccess {
        throw SecKeyError.build(error: .decryptionFailed, message: "Decryption failed", status: status)
      }
      return plainText.subdata(in: 0 ..< plainTextLen)

    #elseif os(macOS)

      var error: Unmanaged<CFError>?

      let transform = SecDecryptTransformCreate(self, &error)
      if error != nil {
        throw error!.takeRetainedValue()
      }

      let secPadding: CFString
      switch padding {
      case .oaep:
        secPadding = kSecPaddingOAEPKey
      case .pkcs1:
        secPadding = kSecPaddingPKCS1Key
      case .none:
        secPadding = kSecPaddingNoneKey
      }

      if !SecTransformSetAttribute(transform, kSecPaddingKey, secPadding, &error) {
        throw error!.takeRetainedValue()
      }

      if !SecTransformSetAttribute(transform, kSecTransformInputAttributeName, cipherText as CFData, &error) {
        throw error!.takeRetainedValue()
      }

      let plainText: CFTypeRef? = SecTransformExecute(transform, &error)
      if plainText == nil {
        throw error!.takeRetainedValue()
      }

      return plainText as! Data

    #endif
  }

  #if os(iOS) || os(watchOS) || os(tvOS)
    private static func paddingOf(digestAlgorithm: Digester.Algorithm) -> SecPadding {
      switch digestAlgorithm {
      case .md2, .md4:
        return .PKCS1MD2
      case .md5:
        return .PKCS1MD5
      case .sha1:
        return .PKCS1SHA1
      case .sha224:
        return .PKCS1SHA224
      case .sha256:
        return .PKCS1SHA256
      case .sha384:
        return .PKCS1SHA384
      case .sha512:
        return .PKCS1SHA512
      }
    }
  #endif

  func sign(data: Data, digestAlgorithm: Digester.Algorithm) throws -> Data {

    let digest = Digester.digest(data, using: digestAlgorithm)

    return try signHash(digest: digest, digestAlgorithm: digestAlgorithm)
  }

  func signHash(digest: Data, digestAlgorithm: Digester.Algorithm) throws -> Data {
      let digestType: SecKeyAlgorithm

      switch digestAlgorithm {
      case .sha1:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA1
        } else {
          digestType = .ecdsaSignatureDigestX962SHA1
        }

      case .sha224:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA224
        } else {
          digestType = .ecdsaSignatureDigestX962SHA224
        }

      case .sha256:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA256
        } else {
          digestType = .ecdsaSignatureDigestX962SHA256
        }

      case .sha384:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA384
        } else {
          digestType = .ecdsaSignatureDigestX962SHA384
        }

      case .sha512:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA512
        } else {
          digestType = .ecdsaSignatureDigestX962SHA512
        }

      default:
        fatalError("unsupported digest algorithm")
      }

      var error: Unmanaged<CFError>?

      guard let signature = SecKeyCreateSignature(self, digestType, digest as CFData, &error) else {
        throw error!.takeRetainedValue()
      }

      return signature as Data
  }

  func verify(data: Data, againstSignature signature: Data, digestAlgorithm: Digester.Algorithm) throws -> Bool {

    let digest = Digester.digest(data, using: digestAlgorithm)

    return try verifyHash(digest: digest, againstSignature: signature, digestAlgorithm: digestAlgorithm)
  }

  func verifyHash(digest: Data, againstSignature signature: Data, digestAlgorithm: Digester.Algorithm) throws -> Bool {
      let digestType: SecKeyAlgorithm

      switch digestAlgorithm {
      case .sha1:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA1
        } else {
          digestType = .ecdsaSignatureDigestX962SHA1
        }

      case .sha224:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA224
        } else {
          digestType = .ecdsaSignatureDigestX962SHA224
        }

      case .sha256:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA256
        } else {
          digestType = .ecdsaSignatureDigestX962SHA256
        }

      case .sha384:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA384
        } else {
          digestType = .ecdsaSignatureDigestX962SHA384
        }

      case .sha512:
        if try! self.keyType() == .rsa {
          digestType = .rsaSignatureDigestPKCS1v15SHA512
        } else {
          digestType = .ecdsaSignatureDigestX962SHA512
        }

      default:
        fatalError("unsupported digest algorithm")
      }

      var error: Unmanaged<CFError>? = nil

      return SecKeyVerifySignature(self, digestType, digest as CFData, signature as CFData, &error)
  }

}

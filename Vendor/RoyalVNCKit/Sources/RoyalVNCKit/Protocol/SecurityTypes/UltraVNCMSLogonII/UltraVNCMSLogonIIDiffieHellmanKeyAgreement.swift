#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol.UltraVNCMSLogonIIAuthentication {
    struct DiffieHellmanKeyAgreement {
        static let maxBits = 31
        static let maxNum = ((UInt64(1)) << maxBits) - 1

        let publicKey: Data
        let privateKey: Data
        let secretKey: Data

        init?(generator: Data,
              modulus: Data,
              resp: Data) {
            guard let keyPair = Self.generateKeyPair(generator: generator,
                                                     modulus: modulus) else {
                return nil
            }

            guard let secretKey = Self.computeSharedKey(modulus: modulus,
                                                        resp: resp,
                                                        privateKey: keyPair.privateKey),
                  !secretKey.isEmpty else {
                return nil
            }

            self.publicKey = keyPair.publicKey
            self.privateKey = keyPair.privateKey
            self.secretKey = secretKey
        }
    }
}

private extension VNCProtocol.UltraVNCMSLogonIIAuthentication.DiffieHellmanKeyAgreement {
    struct KeyPair {
        let publicKey: Data
        let privateKey: Data
    }

    static func generateKeyPair(generator: Data,
                                modulus: Data) -> KeyPair? {
        guard let generatorNum = BigNum(data: generator),
              generatorNum.isLessThan(maxNum) else {
            return nil
        }
        
        guard let modulusNum = BigNum(data: modulus),
              modulusNum.isLessThan(maxNum) else {
            return nil
        }
        
        let privNum = BigNum.randomNumber(lessThan: maxNum)
        guard privNum.isLessThan(maxNum) else { return nil }
        
        guard let privData = privNum.fixedWidthBigEndianData(length: 8) else { return nil }

        let pubNum = generatorNum.power(exponent: privNum,
                                        modulus: modulusNum)
        
        guard let pubData = pubNum.fixedWidthBigEndianData(length: 8) else { return nil }
        
        let keyPair = KeyPair(publicKey: pubData,
                              privateKey: privData)

        return keyPair
    }

    static func computeSharedKey(modulus: Data,
                                 resp: Data,
                                 privateKey: Data) -> Data? {
        guard let privNum = BigNum(data: privateKey) else { return nil }
        guard let modulusNum = BigNum(data: modulus) else { return nil }

        guard let respNum = BigNum(data: resp),
              respNum.isLessThan(maxNum) else {
            return nil
        }

        let keyNum = respNum.power(exponent: privNum,
                                   modulus: modulusNum)

        let keyData = keyNum.fixedWidthBigEndianData(length: 8)

        return keyData
    }
}

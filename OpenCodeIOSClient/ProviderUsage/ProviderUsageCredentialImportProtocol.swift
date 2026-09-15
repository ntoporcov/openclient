import CryptoKit
import Foundation

enum ProviderUsageCredentialImportError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedProfile
    case unsupportedSource
    case contextChanged
    case insecureTransport
    case invalidReady
    case invalidFrame
    case authenticationFailed
    case replay
    case outputTooLarge
    case selectedPayloadTooLarge
    case timedOut
    case connectionFailed
    case ptyCreateFailed
    case ptyCreateHTTPStatus(Int)
    case ptyConnectFailed
    case helperProviderInvalid
    case helperSourceInvalid
    case helperClientKeyInvalid
    case helperPSKInvalid
    case sourceMissing
    case sourceTooLarge
    case malformedSource
    case entryMissing
    case multipleEntries
    case unsupportedEntry
    case cleanupFailed

    var description: String { "ProviderUsageCredentialImportError(\(code))" }

    var code: String {
        switch self {
        case .unsupportedProfile: "UNSUPPORTED_PROFILE"
        case .unsupportedSource: "UNSUPPORTED_SOURCE"
        case .contextChanged: "CONTEXT_CHANGED"
        case .insecureTransport: "INSECURE_TRANSPORT"
        case .invalidReady: "INVALID_READY"
        case .invalidFrame: "INVALID_FRAME"
        case .authenticationFailed: "AUTHENTICATION_FAILED"
        case .replay: "REPLAY"
        case .outputTooLarge: "OUTPUT_TOO_LARGE"
        case .selectedPayloadTooLarge: "SELECTED_PAYLOAD_TOO_LARGE"
        case .timedOut: "TIMED_OUT"
        case .connectionFailed: "CONNECTION_FAILED"
        case .ptyCreateFailed: "PTY_CREATE_FAILED"
        case .ptyCreateHTTPStatus(let status): "PTY_CREATE_HTTP_\(status)"
        case .ptyConnectFailed: "PTY_CONNECT_FAILED"
        case .helperProviderInvalid: "HELPER_PROVIDER_INVALID"
        case .helperSourceInvalid: "HELPER_SOURCE_INVALID"
        case .helperClientKeyInvalid: "HELPER_CLIENT_KEY_INVALID"
        case .helperPSKInvalid: "HELPER_PSK_INVALID"
        case .sourceMissing: "SOURCE_MISSING"
        case .sourceTooLarge: "SOURCE_TOO_LARGE"
        case .malformedSource: "MALFORMED_SOURCE"
        case .entryMissing: "ENTRY_MISSING"
        case .multipleEntries: "MULTIPLE_ENTRIES"
        case .unsupportedEntry: "UNSUPPORTED_ENTRY"
        case .cleanupFailed: "CLEANUP_FAILED"
        }
    }
}

enum ProviderUsageCredentialImportProtocol {
    static let version = "1"
    static let marker = "OCPI"
    static let maximumSourceBytes = 1_048_576
    static let maximumSelectedPayloadBytes = 16_384
    static let maximumOutputBytes = 65_536

    struct Selection: Equatable, Sendable {
        let provider: String
        let source: String
        let credentialKind: ProviderUsageCredentialKind

        init(candidate: ProviderUsageSetupCandidate) throws {
            guard candidate.apiProfile == .legacy,
                  candidate.sourceKind == .openCodeAuth,
                  case let .legacyProvider(providerID) = candidate.sourceIdentity else {
                throw ProviderUsageCredentialImportError.unsupportedSource
            }
            switch (candidate.provider, candidate.credentialKind, providerID) {
            case (.codex, .oauthAccessToken, "openai"):
                provider = "openai"
            case (.openRouter, .apiKey, "openrouter"):
                provider = "openrouter"
            default:
                throw ProviderUsageCredentialImportError.unsupportedSource
            }
            source = "legacy-opencode-auth-v1"
            credentialKind = candidate.credentialKind
        }
    }

    struct Keys: Sendable {
        let clientToServer: SymmetricKey
        let serverToClient: SymmetricKey
    }

    struct Ready: Equatable, Sendable {
        let serverPublicKey: Data
        let transcript: String
    }

    struct ResultPayload: Codable, Equatable, Sendable {
        let ok: Bool
        let credential: String?
        let accountID: String?
        let expires: Double?
        let error: String?
    }

    static func transcript(
        operationID: UUID, selection: Selection, clientPublicKey: Data, serverPublicKey: Data
    ) -> String {
        [marker, version, operationID.uuidString.lowercased(), selection.provider, selection.source,
         clientPublicKey.base64EncodedString(), serverPublicKey.base64EncodedString()].joined(separator: "|")
    }

    static func authenticateReady(
        _ line: String, operationID: UUID, selection: Selection, clientPublicKey: Data, psk: Data
    ) throws -> Ready {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9, fields[0] == marker, fields[1] == version, fields[2] == "READY",
              fields[3] == operationID.uuidString.lowercased(), fields[4] == selection.provider,
              fields[5] == selection.source, fields[6] == "0",
              let serverPublicKey = Data(base64Encoded: fields[7]), serverPublicKey.count == 32,
              let authenticator = Data(base64Encoded: fields[8]) else {
            throw ProviderUsageCredentialImportError.invalidReady
        }
        let value = transcript(operationID: operationID, selection: selection,
                               clientPublicKey: clientPublicKey, serverPublicKey: serverPublicKey)
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: Data("\(value)|READY|0".utf8), using: SymmetricKey(data: psk)
        ))
        guard constantTimeEqual(expected, authenticator) else {
            throw ProviderUsageCredentialImportError.authenticationFailed
        }
        return Ready(serverPublicKey: serverPublicKey, transcript: value)
    }

    static func deriveKeys(
        privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data, psk: Data, transcript: String
    ) throws -> Keys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return Keys(
            clientToServer: shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: psk, sharedInfo: Data("\(transcript)|c2s".utf8), outputByteCount: 32
            ),
            serverToClient: shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: psk, sharedInfo: Data("\(transcript)|s2c".utf8), outputByteCount: 32
            )
        )
    }

    static func startFrame(
        operationID: UUID, selection: Selection, transcript: String, key: SymmetricKey, nonce: Data
    ) throws -> String {
        try sealFrame(type: "START", direction: "c2s", sequence: 0, operationID: operationID,
                      selection: selection, transcript: transcript, key: key, nonce: nonce, plaintext: Data("{}".utf8))
    }

    static func resultFrame(
        _ payload: ResultPayload, operationID: UUID, selection: Selection, transcript: String,
        key: SymmetricKey, nonce: Data
    ) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= maximumSelectedPayloadBytes else {
            throw ProviderUsageCredentialImportError.selectedPayloadTooLarge
        }
        return try sealFrame(type: "RESULT", direction: "s2c", sequence: 1, operationID: operationID,
                             selection: selection, transcript: transcript, key: key, nonce: nonce, plaintext: data)
    }

    static func openResult(
        _ line: String, operationID: UUID, selection: Selection, transcript: String, key: SymmetricKey
    ) throws -> ResultPayload {
        let data = try openFrame(line, type: "RESULT", direction: "s2c", sequence: 1,
                                 operationID: operationID, selection: selection, transcript: transcript, key: key)
        guard data.count <= maximumSelectedPayloadBytes else {
            throw ProviderUsageCredentialImportError.selectedPayloadTooLarge
        }
        do { return try JSONDecoder().decode(ResultPayload.self, from: data) }
        catch { throw ProviderUsageCredentialImportError.invalidFrame }
    }

    static func openStart(
        _ line: String, operationID: UUID, selection: Selection, transcript: String, key: SymmetricKey
    ) throws {
        let data = try openFrame(line, type: "START", direction: "c2s", sequence: 0,
                                 operationID: operationID, selection: selection, transcript: transcript, key: key)
        guard data == Data("{}".utf8) else { throw ProviderUsageCredentialImportError.invalidFrame }
    }

    private static func sealFrame(
        type: String, direction: String, sequence: Int, operationID: UUID, selection: Selection,
        transcript: String, key: SymmetricKey, nonce: Data, plaintext: Data
    ) throws -> String {
        guard nonce.count == 12 else { throw ProviderUsageCredentialImportError.invalidFrame }
        let nonceValue = try ChaChaPoly.Nonce(data: nonce)
        let nonceText = nonce.base64EncodedString()
        let aad = Data("\(transcript)|\(direction)|\(type)|\(sequence)|\(nonceText)".utf8)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonceValue, authenticating: aad)
        let sealed = box.ciphertext + box.tag
        return [marker, version, type, operationID.uuidString.lowercased(), selection.provider,
                selection.source, String(sequence), nonceText, sealed.base64EncodedString()].joined(separator: "|")
    }

    private static func openFrame(
        _ line: String, type: String, direction: String, sequence: Int, operationID: UUID,
        selection: Selection, transcript: String, key: SymmetricKey
    ) throws -> Data {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9, fields[0] == marker, fields[1] == version, fields[2] == type,
              fields[3] == operationID.uuidString.lowercased(), fields[4] == selection.provider,
              fields[5] == selection.source, fields[6] == String(sequence),
              let nonce = Data(base64Encoded: fields[7]), nonce.count == 12,
              let sealed = Data(base64Encoded: fields[8]), sealed.count >= 16 else {
            throw ProviderUsageCredentialImportError.invalidFrame
        }
        let aad = Data("\(transcript)|\(direction)|\(type)|\(sequence)|\(fields[7])".utf8)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)
            )
            return try ChaChaPoly.open(box, using: key, authenticating: aad)
        } catch {
            throw ProviderUsageCredentialImportError.authenticationFailed
        }
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Public helper code is intentionally nonsecret. The operation PSK is supplied only in
/// the PTY environment, which upstream excludes from PTY Info, inventory, and events.
enum ProviderUsageCredentialImportHelper {
    static let title = "OpenClient Credential Import"
    static let sourceEnvironmentKey = "OCPI_HELPER_SOURCE"
    static let launchCommand = #"command -v node >/dev/null 2>&1 || exit 127; exec node -e "$OCPI_HELPER_SOURCE""#
    static let arguments = ["-lic", launchCommand]

    static let source = #"""
const c=require('node:crypto'),fs=require('node:fs'),path=require('node:path');
const M='OCPI',V='1',MAX=1048576,OUT=16384;
const op=process.env.OCPI_OPERATION_ID,provider=process.env.OCPI_PROVIDER,source=process.env.OCPI_SOURCE;
const client=Buffer.from(process.env.OCPI_CLIENT_PUBLIC_KEY||'','base64'),psk=Buffer.from(process.env.OCPI_PSK||'','base64');
const b64=x=>Buffer.from(x).toString('base64'),rawPublic=k=>k.export({type:'spki',format:'der'}).subarray(-32);
const spki=x=>Buffer.concat([Buffer.from('302a300506032b656e032100','hex'),x]);
const fail=code=>{process.stdout.write('OCPI|1|ERROR|'+code+'\n');process.exit(2)};
if(provider!=='openai'&&provider!=='openrouter')fail('INVALID_PROVIDER');
if(source!=='legacy-opencode-auth-v1')fail('INVALID_SOURCE');
if(client.length!==32)fail('INVALID_CLIENT_KEY');
if(psk.length!==32)fail('INVALID_PSK');
const pair=c.generateKeyPairSync('x25519'),server=rawPublic(pair.publicKey);
const transcript=[M,V,op,provider,source,b64(client),b64(server)].join('|');
const auth=c.createHmac('sha256',psk).update(transcript+'|READY|0').digest();
process.stdin.setRawMode?.(true);process.stdin.setEncoding('utf8');
process.stdout.write([M,V,'READY',op,provider,source,'0',b64(server),b64(auth)].join('|')+'\n');
let input='',started=false,finished=false,timer=setTimeout(()=>fail('TIMED_OUT'),30000);
const key=dir=>c.hkdfSync('sha256',c.diffieHellman({privateKey:pair.privateKey,publicKey:c.createPublicKey({key:spki(client),format:'der',type:'spki'})}),psk,Buffer.from(transcript+'|'+dir),32);
const aad=(dir,type,seq,nonce)=>Buffer.from(transcript+'|'+dir+'|'+type+'|'+seq+'|'+nonce);
function openStart(line){const f=line.split('|');if(f.length!==9||f.slice(0,7).join('|')!==[M,V,'START',op,provider,source,'0'].join('|'))fail('INVALID_FRAME');
 const n=Buffer.from(f[7],'base64'),box=Buffer.from(f[8],'base64');if(n.length!==12||box.length<16)fail('INVALID_FRAME');
 try{const d=c.createDecipheriv('chacha20-poly1305',key('c2s'),n,{authTagLength:16});d.setAAD(aad('c2s','START',0,f[7]));d.setAuthTag(box.subarray(-16));
  if(Buffer.concat([d.update(box.subarray(0,-16)),d.final()]).toString()!=='{}')fail('INVALID_FRAME');}catch{fail('AUTHENTICATION_FAILED')}}
function sealResult(payload){if(finished)return;finished=true;clearTimeout(timer);const plain=Buffer.from(JSON.stringify(payload));if(plain.length>OUT)fail('SELECTED_PAYLOAD_TOO_LARGE');const n=c.randomBytes(12),ns=b64(n);
 const e=c.createCipheriv('chacha20-poly1305',key('s2c'),n,{authTagLength:16});e.setAAD(aad('s2c','RESULT',1,ns));const box=Buffer.concat([e.update(plain),e.final(),e.getAuthTag()]);
 process.stdout.write([M,V,'RESULT',op,provider,source,'1',ns,b64(box)].join('|')+'\n',()=>process.exit(0))}
 function result(){if(process.env.OPENCODE_AUTH_CONTENT)return sealResult({ok:false,error:'UNSUPPORTED_SOURCE'});const base=process.env.XDG_DATA_HOME||(process.env.HOME?path.join(process.env.HOME,'.local','share'):null);if(!base)return sealResult({ok:false,error:'SOURCE_MISSING'});let file=path.join(base,'opencode','auth.json'),chunks=[],size=0,s=fs.createReadStream(file,{highWaterMark:65536});
 s.on('data',x=>{size+=x.length;if(size>MAX){s.destroy(Object.assign(new Error(),{code:'SOURCE_TOO_LARGE'}));return}chunks.push(x)});
 s.on('error',e=>sealResult({ok:false,error:e.code==='ENOENT'?'SOURCE_MISSING':e.code==='SOURCE_TOO_LARGE'?'SOURCE_TOO_LARGE':'MALFORMED_SOURCE'}));
 s.on('end',()=>{let root;try{root=JSON.parse(Buffer.concat(chunks).toString('utf8'))}catch{return sealResult({ok:false,error:'MALFORMED_SOURCE'})}
  if(!root||Array.isArray(root)||typeof root!=='object')return sealResult({ok:false,error:'MALFORMED_SOURCE'});const entry=root[provider];if(entry===undefined)return sealResult({ok:false,error:'ENTRY_MISSING'});
  if(Array.isArray(entry))return sealResult({ok:false,error:entry.length>1?'MULTIPLE_ENTRIES':'UNSUPPORTED_ENTRY'});if(!entry||typeof entry!=='object')return sealResult({ok:false,error:'UNSUPPORTED_ENTRY'});
  if(provider==='openai'&&entry.type==='oauth'&&typeof entry.access==='string'&&entry.access.length)return sealResult({ok:true,credential:entry.access,accountID:typeof entry.accountId==='string'?entry.accountId:null,expires:Number.isFinite(entry.expires)?entry.expires:null});
  if(provider==='openrouter'&&entry.type==='api'&&typeof entry.key==='string'&&entry.key.length)return sealResult({ok:true,credential:entry.key});return sealResult({ok:false,error:'UNSUPPORTED_ENTRY'})})}
process.stdin.on('data',x=>{input+=x;if(input.length>32768)fail('INVALID_FRAME');let i;while((i=input.indexOf('\n'))>=0){let line=input.slice(0,i).replace(/\r$/,'');input=input.slice(i+1);if(!line.startsWith('OCPI|'))continue;if(started)fail('REPLAY');started=true;clearTimeout(timer);openStart(line);result()}});
"""#

    static func owns(_ pty: OpenCodePTY) -> Bool {
        pty.title == title && pty.args == arguments
    }
}

// Pure contract mirror for synthetic fixtures. It never resolves or reads a path.
enum ProviderUsageCredentialImportFixtureExtractor {
    static func extract(
        _ source: Data, selection: ProviderUsageCredentialImportProtocol.Selection
    ) throws -> ProviderUsageCredentialImportProtocol.ResultPayload {
        guard source.count <= ProviderUsageCredentialImportProtocol.maximumSourceBytes else {
            throw ProviderUsageCredentialImportError.sourceTooLarge
        }
        let root: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: source) as? [String: Any] else {
                throw ProviderUsageCredentialImportError.malformedSource
            }
            root = value
        } catch let error as ProviderUsageCredentialImportError {
            throw error
        } catch {
            throw ProviderUsageCredentialImportError.malformedSource
        }
        guard let raw = root[selection.provider] else { throw ProviderUsageCredentialImportError.entryMissing }
        if let entries = raw as? [Any] {
            if entries.count > 1 { throw ProviderUsageCredentialImportError.multipleEntries }
            throw ProviderUsageCredentialImportError.unsupportedEntry
        }
        guard let entry = raw as? [String: Any] else {
            throw ProviderUsageCredentialImportError.unsupportedEntry
        }
        let payload: ProviderUsageCredentialImportProtocol.ResultPayload
        switch (selection.provider, entry["type"] as? String) {
        case ("openai", "oauth"):
            guard let access = entry["access"] as? String, !access.isEmpty else {
                throw ProviderUsageCredentialImportError.unsupportedEntry
            }
            payload = .init(ok: true, credential: access, accountID: entry["accountId"] as? String,
                            expires: entry["expires"] as? Double, error: nil)
        case ("openrouter", "api"):
            guard let key = entry["key"] as? String, !key.isEmpty else {
                throw ProviderUsageCredentialImportError.unsupportedEntry
            }
            payload = .init(ok: true, credential: key, accountID: nil, expires: nil, error: nil)
        default:
            throw ProviderUsageCredentialImportError.unsupportedEntry
        }
        guard try JSONEncoder().encode(payload).count <= ProviderUsageCredentialImportProtocol.maximumSelectedPayloadBytes else {
            throw ProviderUsageCredentialImportError.selectedPayloadTooLarge
        }
        return payload
    }
}

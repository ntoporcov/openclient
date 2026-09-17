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
    case sourceRefreshNetwork
    case sourceRefreshRejected
    case sourceRefreshMalformed
    case sourceRefreshWriteFailed
    case sourceChanged
    case accountMismatch
    case unsupportedRuntime

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
        case .sourceRefreshNetwork: "SOURCE_REFRESH_NETWORK"
        case .sourceRefreshRejected: "SOURCE_REFRESH_REJECTED"
        case .sourceRefreshMalformed: "SOURCE_REFRESH_MALFORMED"
        case .sourceRefreshWriteFailed: "SOURCE_REFRESH_WRITE_FAILED"
        case .sourceChanged: "SOURCE_CHANGED"
        case .accountMismatch: "ACCOUNT_MISMATCH"
        case .unsupportedRuntime: "UNSUPPORTED_RUNTIME"
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
        enum Action: String, Equatable, Sendable { case read, renew }
        let provider: String
        let source: String
        let credentialKind: ProviderUsageCredentialKind
        let action: Action
        let expectedAccountBinding: String
        let currentAccessBinding: String

        init(
            candidate: ProviderUsageSetupCandidate,
            action: Action = .read,
            expectedAccountID: String? = nil,
            currentAccessToken: String? = nil
        ) throws {
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
            if action == .renew, candidate.provider != .codex {
                throw ProviderUsageCredentialImportError.unsupportedSource
            }
            if action == .renew {
                guard let expectedAccountID, !expectedAccountID.isEmpty,
                      let currentAccessToken, !currentAccessToken.isEmpty else {
                    throw ProviderUsageCredentialImportError.accountMismatch
                }
                expectedAccountBinding = Self.binding(expectedAccountID)
                currentAccessBinding = Self.binding(currentAccessToken)
            } else {
                expectedAccountBinding = "-"
                currentAccessBinding = "-"
            }
            source = action == .read ? "legacy-opencode-auth-v1" : "legacy-opencode-auth-renew-v1"
            credentialKind = candidate.credentialKind
            self.action = action
        }

        private static func binding(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
         selection.expectedAccountBinding, selection.currentAccessBinding,
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
const expected=process.env.OCPI_EXPECTED_ACCOUNT_BINDING,currentAccess=process.env.OCPI_CURRENT_ACCESS_BINDING;
const client=Buffer.from(process.env.OCPI_CLIENT_PUBLIC_KEY||'','base64'),psk=Buffer.from(process.env.OCPI_PSK||'','base64');
const b64=x=>Buffer.from(x).toString('base64'),rawPublic=k=>k.export({type:'spki',format:'der'}).subarray(-32);
const spki=x=>Buffer.concat([Buffer.from('302a300506032b656e032100','hex'),x]);
const sha=x=>c.createHash('sha256').update(x).digest('hex');
const fail=code=>{process.stdout.write('OCPI|1|ERROR|'+code+'\n');process.exit(2)};
if(provider!=='openai'&&provider!=='openrouter')fail('INVALID_PROVIDER');
if(source!=='legacy-opencode-auth-v1'&&source!=='legacy-opencode-auth-renew-v1')fail('INVALID_SOURCE');
if(client.length!==32)fail('INVALID_CLIENT_KEY');
if(psk.length!==32)fail('INVALID_PSK');
if(!fs.promises||typeof fs.promises.open!=='function'||typeof fs.promises.rename!=='function'||typeof fs.promises.mkdir!=='function'||typeof fs.promises.rmdir!=='function'||typeof fs.constants.O_NOFOLLOW!=='number'||typeof c.hkdfSync!=='function')fail('UNSUPPORTED_RUNTIME');
if(source==='legacy-opencode-auth-renew-v1'&&(typeof fetch!=='function'||typeof URLSearchParams!=='function'||typeof AbortSignal==='undefined'||typeof AbortSignal.timeout!=='function'))fail('UNSUPPORTED_RUNTIME');
if(source==='legacy-opencode-auth-renew-v1'&&(!/^[0-9a-f]{64}$/.test(expected||'')||!/^[0-9a-f]{64}$/.test(currentAccess||'')))fail('INVALID_SOURCE');
const pair=c.generateKeyPairSync('x25519'),server=rawPublic(pair.publicKey);
const transcript=[M,V,op,provider,source,expected,currentAccess,b64(client),b64(server)].join('|');
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
 const coded=(code,error)=>Object.assign(error||new Error(),{code}),jwtAccount=t=>{if(typeof t!=='string')return null;const p=t.split('.');if(p.length!==3)return null;try{const x=JSON.parse(Buffer.from(p[1],'base64url'));return x.chatgpt_account_id||x['https://api.openai.com/auth']?.chatgpt_account_id||x.organizations?.[0]?.id||null}catch{return null}};
 const accountOf=entry=>(typeof entry?.accountId==='string'&&entry.accountId.trim())||jwtAccount(entry?.access);
 async function readAuth(file){let handle,data;try{handle=await fs.promises.open(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);const stat=await handle.stat();if(!stat.isFile())throw coded('MALFORMED_SOURCE');if(stat.size>MAX)throw coded('SOURCE_TOO_LARGE');data=await handle.readFile();if(data.length>MAX)throw coded('SOURCE_TOO_LARGE')}catch(e){if(e.code==='SOURCE_TOO_LARGE'||e.code==='MALFORMED_SOURCE')throw e;throw coded(e.code==='ENOENT'?'SOURCE_MISSING':'MALFORMED_SOURCE')}finally{try{await handle?.close()}catch{}}let root;try{root=JSON.parse(data.toString('utf8'))}catch{throw coded('MALFORMED_SOURCE')}if(!root||Array.isArray(root)||typeof root!=='object')throw coded('MALFORMED_SOURCE');return {bytes:data,root}}
 async function acquireLock(file){const lock=path.join(path.dirname(file),'.auth.json.ocpi-renew.lock'),until=Date.now()+2000;for(;;){try{await fs.promises.mkdir(lock,{mode:0o700});let owned=true;return async()=>{if(!owned)return;owned=false;try{await fs.promises.rmdir(lock)}catch{}}}catch(e){if(e.code!=='EEXIST')throw coded('SOURCE_REFRESH_WRITE_FAILED');if(Date.now()>=until)throw coded('SOURCE_CHANGED');await new Promise(resolve=>setTimeout(resolve,50))}}}
 const currentResult=entry=>{const accountId=accountOf(entry);if(!accountId||sha(accountId)!==expected)throw coded('ACCOUNT_MISMATCH');if(typeof entry.access!=='string'||!entry.access.length||!Number.isFinite(entry.expires))throw coded('SOURCE_REFRESH_MALFORMED');return {ok:true,credential:entry.access,accountID:accountId,expires:entry.expires}};
 async function renew(file,entry){if(provider!=='openai'||entry.type!=='oauth'||typeof entry.refresh!=='string'||!entry.refresh.length||typeof entry.access!=='string'||!entry.access.length)throw coded('SOURCE_REFRESH_MALFORMED');const sourceAccount=accountOf(entry);if(!sourceAccount||sha(sourceAccount)!==expected)throw coded('ACCOUNT_MISMATCH');if(sha(entry.access)!==currentAccess)return currentResult(entry);let response;
  try{response=await fetch('https://auth.openai.com/oauth/token',{method:'POST',redirect:'error',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'refresh_token',refresh_token:entry.refresh,client_id:'app_EMoamEEZ73f0CkXaXp7hrann'}).toString(),signal:AbortSignal.timeout(5000)})}catch{throw Object.assign(new Error(),{code:'SOURCE_REFRESH_NETWORK'})}
  if(!response.ok)throw Object.assign(new Error(),{code:'SOURCE_REFRESH_REJECTED'});let chunks=[],total=0;try{const reader=response.body.getReader();for(;;){const x=await reader.read();if(x.done)break;total+=x.value.length;if(total>OUT){await reader.cancel();throw new Error()}chunks.push(Buffer.from(x.value))}}catch{throw Object.assign(new Error(),{code:'SOURCE_REFRESH_MALFORMED'})}
  let tokens;try{tokens=JSON.parse(Buffer.concat(chunks).toString('utf8'))}catch{throw Object.assign(new Error(),{code:'SOURCE_REFRESH_MALFORMED'})}if(!tokens||typeof tokens.access_token!=='string'||!tokens.access_token.length||tokens.expires_in!==undefined&&(!Number.isFinite(tokens.expires_in)||tokens.expires_in<=0))throw Object.assign(new Error(),{code:'SOURCE_REFRESH_MALFORMED'});
  const accountId=jwtAccount(tokens.id_token)||jwtAccount(tokens.access_token)||sourceAccount;if(!accountId||sha(accountId)!==expected)throw coded('ACCOUNT_MISMATCH');const refreshed={access:tokens.access_token,refresh:typeof tokens.refresh_token==='string'&&tokens.refresh_token.length?tokens.refresh_token:entry.refresh,expires:Date.now()+(tokens.expires_in??3600)*1000,accountId};
  for(let attempt=0;attempt<3;attempt++){const latest=await readAuth(file),currentEntry=latest.root[provider];if(!currentEntry||Array.isArray(currentEntry)||typeof currentEntry!=='object')throw coded('SOURCE_REFRESH_MALFORMED');const currentAccount=accountOf(currentEntry);if(!currentAccount||sha(currentAccount)!==expected)throw coded('ACCOUNT_MISMATCH');if(currentEntry.access!==entry.access||currentEntry.refresh!==entry.refresh)return currentResult(currentEntry);const merged={...latest.root,[provider]:{...currentEntry,...refreshed}},temp=path.join(path.dirname(file),'.auth.json.ocpi-'+op+'-'+process.pid+'-'+attempt);let handle;try{handle=await fs.promises.open(temp,'wx',0o600);await handle.writeFile(JSON.stringify(merged,null,2)+'\n',{encoding:'utf8'});await handle.sync();await handle.chmod(0o600);await handle.close();handle=null;const verified=await readAuth(file);if(!verified.bytes.equals(latest.bytes)){await fs.promises.unlink(temp);continue}await fs.promises.rename(temp,file)}catch(e){try{await handle?.close()}catch{}try{await fs.promises.unlink(temp)}catch{}if(e.code==='SOURCE_CHANGED')throw e;throw coded('SOURCE_REFRESH_WRITE_FAILED')}try{const dir=await fs.promises.open(path.dirname(file),'r');try{await dir.sync()}finally{await dir.close()}}catch{}return {ok:true,credential:refreshed.access,accountID:accountId,expires:refreshed.expires}}throw coded('SOURCE_CHANGED')}
 async function selectedResult(){if(process.env.OPENCODE_AUTH_CONTENT)throw coded('UNSUPPORTED_SOURCE');const base=process.env.XDG_DATA_HOME||(process.env.HOME?path.join(process.env.HOME,'.local','share'):null);if(!base)throw coded('SOURCE_MISSING');const file=path.join(base,'opencode','auth.json');let release;try{if(source==='legacy-opencode-auth-renew-v1')release=await acquireLock(file);const original=await readAuth(file),entry=original.root[provider];if(entry===undefined)throw coded('ENTRY_MISSING');if(Array.isArray(entry))throw coded(entry.length>1?'MULTIPLE_ENTRIES':'UNSUPPORTED_ENTRY');if(!entry||typeof entry!=='object')throw coded('UNSUPPORTED_ENTRY');if(source==='legacy-opencode-auth-renew-v1')return await renew(file,entry);if(provider==='openai'&&entry.type==='oauth'&&typeof entry.access==='string'&&entry.access.length)return {ok:true,credential:entry.access,accountID:typeof entry.accountId==='string'?entry.accountId:null,expires:Number.isFinite(entry.expires)?entry.expires:null};if(provider==='openrouter'&&entry.type==='api'&&typeof entry.key==='string'&&entry.key.length)return {ok:true,credential:entry.key};throw coded('UNSUPPORTED_ENTRY')}finally{if(release)await release()}}
 function result(){selectedResult().then(sealResult).catch(e=>{const allowed=['UNSUPPORTED_SOURCE','SOURCE_MISSING','SOURCE_TOO_LARGE','MALFORMED_SOURCE','ENTRY_MISSING','MULTIPLE_ENTRIES','UNSUPPORTED_ENTRY','SOURCE_REFRESH_NETWORK','SOURCE_REFRESH_REJECTED','SOURCE_REFRESH_MALFORMED','SOURCE_REFRESH_WRITE_FAILED','SOURCE_CHANGED','ACCOUNT_MISMATCH'];sealResult({ok:false,error:allowed.includes(e.code)?e.code:'SOURCE_REFRESH_WRITE_FAILED'})})}
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

import Foundation
import AppKit

struct GaoActionCapability {
    let action: String
    let parameterSchema: [String:GaoJSONValue]
    let details: [String:GaoJSONValue]
    func accepts(parameterKeys: Set<String>) -> Bool {
        guard let properties = parameterSchema["properties"]?.objectValue else { return parameterKeys.isEmpty }
        return parameterKeys.isSubset(of:Set(properties.keys))
    }
}

struct GaoInstalledProvider {
    let bundleID: String
    let applicationURL: URL
    let appVersion: String
    let capability: GaoActionCapability
}

enum GaoCapabilityDiscovery {
    @MainActor static func installedProvider(bundleID: String, action: String) throws -> GaoInstalledProvider? {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) else { return nil }
        return try provider(applicationURL:application,bundleID:bundleID,action:action)
    }
    static func provider(applicationURL: URL, bundleID: String, action: String) throws -> GaoInstalledProvider? {
        guard GaoActionContract.validBundleID(bundleID), GaoActionContract.knownActions.contains(action), let bundle = Bundle(url:applicationURL), bundle.bundleIdentifier == bundleID, let version = bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String, let resource = bundle.url(forResource:"GaoCapabilities",withExtension:"json") else { return nil }
        let bytes = try GaoPrivateIO.read(GaoPrivateIO.regularURL(resource),maximum:Int64(GaoActionContract.maximumManifestBytes))
        let json: [String:GaoJSONValue]
        do { json = try JSONDecoder().decode([String:GaoJSONValue].self,from:bytes) }
        catch { throw GaoActionContract.reject("invalidCapabilities","目标应用能力表损坏，不能发送动作。") }
        guard json["schemaVersion"]?.numberValue == 1, json["bundleID"]?.stringValue == bundleID, json["appVersion"]?.stringValue == version else { throw GaoActionContract.reject("invalidCapabilities","目标应用能力表版本或身份不匹配。") }
        let actions:[GaoJSONValue]
        if let array=json["actions"]?.arrayValue {actions=array}
        else if let dictionary=json["actions"]?.objectValue {
            // Existing V1 providers use both an array and an action-keyed dictionary.
            // A dictionary key is an action declaration, never an executable command.
            actions=try dictionary.keys.sorted().map { name in
                guard var entry=dictionary[name]?.objectValue,
                      entry["action"] == nil || entry["action"]?.stringValue == name,
                      entry["name"] == nil || entry["name"]?.stringValue == name else {throw GaoActionContract.reject("invalidCapabilities","目标应用动作声明冲突或无效。")}
                entry["action"] = .string(name)
                return .object(entry)
            }
        }else{throw GaoActionContract.reject("invalidCapabilities","目标应用能力列表无效。")}
        var found: GaoActionCapability?
        var seen = Set<String>()
        for entry in actions {
            guard let object = entry.objectValue else { throw GaoActionContract.reject("invalidCapabilities","目标应用动作声明无效。") }
            // V1 fixes semantics, but did not prescribe an action-entry key. Accept either spelling, never conflicting values.
            let actionName = object["action"]?.stringValue ?? object["name"]?.stringValue
            guard let name = actionName, GaoActionContract.knownActions.contains(name), seen.insert(name).inserted, object["action"] == nil || object["name"] == nil || object["action"] == object["name"] else { throw GaoActionContract.reject("invalidCapabilities","目标应用动作声明重复或无效。") }
            let schema = object["parametersSchema"]?.objectValue ?? object["parameterSchema"]?.objectValue ?? object["parameters"]?.objectValue
            guard let schema, schema["type"]?.stringValue == "object", schema["additionalProperties"]?.boolValue == false, schema["properties"]?.objectValue != nil else { throw GaoActionContract.reject("invalidCapabilities","目标动作缺少严格参数声明。") }
            if name == action { found = GaoActionCapability(action:name,parameterSchema:schema,details:object) }
        }
        guard let capability = found else { return nil }
        return GaoInstalledProvider(bundleID:bundleID,applicationURL:applicationURL,appVersion:version,capability:capability)
    }
    @MainActor static func send(packageURL: URL, to provider: GaoInstalledProvider, completion: @escaping (Error?) -> Void) {
        // Recheck the exact installed bundle immediately before the explicit NSWorkspace handoff.
        do {
            guard let current = try self.provider(applicationURL:provider.applicationURL,bundleID:provider.bundleID,action:provider.capability.action), current.appVersion == provider.appVersion else { throw GaoActionContract.reject("providerChanged","目标应用已变化，请重新检查能力。") }
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.open([packageURL],withApplicationAt:provider.applicationURL,configuration:config) { _,error in completion(error) }
        } catch { completion(error) }
    }
}

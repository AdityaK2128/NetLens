import Foundation
import CoreWLAN
import CoreLocation

struct WiFiStatus: Equatable {
    var interfaceName: String?
    var powerOn = false
    var ssid: String?
    var bssid: String?
    var rssi: Int?
    var noise: Int?
    var txRate: Double?
    var txPower: Int?
    var channel: Int?
    var band: String?
    var bandGHz: Double?
    var channelWidth: Int?
    var phyMode: String?
    var security: String?
    var countryCode: String?
    var hardwareAddress: String?
    var interfaceMode: String?

    var snr: Int? {
        guard let rssi, let noise, noise != 0 else { return nil }
        return rssi - noise
    }
    var isAssociated: Bool { rssi != nil && rssi != 0 }

    /// Rough centre frequency (MHz) for the current channel.
    var frequencyMHz: Int? {
        guard let channel, let bandGHz else { return nil }
        return WiFiMath.frequency(channel: channel, bandGHz: bandGHz)
    }
}

struct WiFiNetwork: Identifiable, Hashable {
    var id: String { (bssid ?? "") + (ssid ?? "") + "\(channel)" }
    let ssid: String?
    let bssid: String?
    let rssi: Int
    let noise: Int
    let channel: Int
    let bandGHz: Double
    let width: Int
    let security: String
    let beaconInterval: Int
    let countryCode: String?
    let isCurrent: Bool
}

enum WiFiMath {
    static func frequency(channel: Int, bandGHz: Double) -> Int {
        if bandGHz < 3 { return channel == 14 ? 2484 : 2407 + channel * 5 }
        if bandGHz < 5.9 && bandGHz > 4 { return 5000 + channel * 5 }
        return 5950 + channel * 5   // 6 GHz
    }

    /// Free-space path-loss distance estimate — a fun, very rough "how far is the AP".
    static func estimatedDistanceMeters(rssi: Int, frequencyMHz: Int, txPowerDBm: Double = 20) -> Double {
        let fspl = txPowerDBm - Double(rssi)
        let exp = (fspl - 20 * log10(Double(frequencyMHz)) + 27.55) / 20
        return pow(10, exp)
    }
}

final class WiFiService: NSObject, CLLocationManagerDelegate {
    private let client = CWWiFiClient.shared()
    private let location = CLLocationManager()
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        location.delegate = self
    }

    var authorization: CLAuthorizationStatus { location.authorizationStatus }

    /// SSID/BSSID are location-gated by macOS; everything else is readable without it.
    func requestLocationAccess() {
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    func status() -> WiFiStatus {
        var s = WiFiStatus()
        guard let i = client.interface() else { return s }
        s.interfaceName = i.interfaceName
        s.powerOn = i.powerOn()
        s.ssid = i.ssid()
        s.bssid = i.bssid()
        let rssi = i.rssiValue()
        s.rssi = rssi == 0 ? nil : rssi
        let noise = i.noiseMeasurement()
        s.noise = noise == 0 ? nil : noise
        let rate = i.transmitRate()
        s.txRate = rate > 0 ? rate : nil
        let txp = i.transmitPower()
        s.txPower = txp > 0 ? txp : nil
        if let ch = i.wlanChannel() {
            s.channel = ch.channelNumber
            (s.band, s.bandGHz) = Self.band(ch.channelBand)
            s.channelWidth = Self.width(ch.channelWidth)
        }
        s.phyMode = Self.phy(i.activePHYMode())
        s.security = Self.security(i.security())
        s.countryCode = i.countryCode()
        s.hardwareAddress = i.hardwareAddress()
        s.interfaceMode = Self.mode(i.interfaceMode())
        return s
    }

    /// Active scan. Blocks for a couple of seconds — call off the main thread.
    func scan() throws -> [WiFiNetwork] {
        guard let i = client.interface() else { return [] }
        let currentBSSID = i.bssid()
        let currentSSID = i.ssid()
        let nets = try i.scanForNetworks(withName: nil, includeHidden: true)
        return nets.map { n in
            let ch = n.wlanChannel
            let (_, ghz) = Self.band(ch?.channelBand ?? .bandUnknown)
            return WiFiNetwork(
                ssid: n.ssid, bssid: n.bssid, rssi: n.rssiValue, noise: n.noiseMeasurement,
                channel: ch?.channelNumber ?? 0, bandGHz: ghz ?? 0, width: Self.width(ch?.channelWidth ?? .widthUnknown) ?? 20,
                security: Self.networkSecurity(n), beaconInterval: n.beaconInterval, countryCode: n.countryCode,
                isCurrent: (n.bssid != nil && n.bssid == currentBSSID) || (currentBSSID == nil && n.ssid != nil && n.ssid == currentSSID && n.rssiValue == i.rssiValue()))
        }
        .sorted { $0.rssi > $1.rssi }
    }

    // MARK: decoding

    static func band(_ b: CWChannelBand) -> (String?, Double?) {
        switch b {
        case .band2GHz: return ("2.4 GHz", 2.4)
        case .band5GHz: return ("5 GHz", 5)
        case .band6GHz: return ("6 GHz", 6)
        default: return (nil, nil)
        }
    }

    static func width(_ w: CWChannelWidth) -> Int? {
        switch w {
        case .width20MHz: return 20
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        default: return nil
        }
    }

    static func phy(_ m: CWPHYMode) -> String? {
        switch m {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n · Wi-Fi 4"
        case .mode11ac: return "802.11ac · Wi-Fi 5"
        case .mode11ax: return "802.11ax · Wi-Fi 6"
        default:
            // Newer SDKs add 802.11be (Wi-Fi 7) as raw value 7.
            if m.rawValue == 7 { return "802.11be · Wi-Fi 7" }
            return nil
        }
    }

    static func security(_ s: CWSecurity) -> String? {
        switch s {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .OWE: return "OWE (Enhanced Open)"
        case .oweTransition: return "OWE Transition"
        default: return nil
        }
    }

    static func networkSecurity(_ n: CWNetwork) -> String {
        let order: [(CWSecurity, String)] = [
            (.wpa3Enterprise, "WPA3-E"), (.wpa3Personal, "WPA3"), (.wpa3Transition, "WPA2/3"),
            (.wpa2Enterprise, "WPA2-E"), (.wpa2Personal, "WPA2"), (.wpaPersonalMixed, "WPA/2"),
            (.wpaPersonal, "WPA"), (.OWE, "OWE"), (.WEP, "WEP"), (.none, "Open"),
        ]
        for (sec, label) in order where n.supportsSecurity(sec) { return label }
        return "?"
    }

    static func mode(_ m: CWInterfaceMode) -> String? {
        switch m {
        case .station: return "Station"
        case .IBSS: return "IBSS (ad-hoc)"
        case .hostAP: return "Host AP"
        default: return nil
        }
    }
}

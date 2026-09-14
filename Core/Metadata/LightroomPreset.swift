import Foundation

/// Lê presets do Lightroom (`.xmp` com o namespace `crs:`) e converte o que tem equivalente nos sliders desta app.
enum LightroomPreset {
    struct Parsed: Sendable {
        var name: String?
        var recipe: EditRecipe
    }

    static func parse(_ data: Data) -> Parsed? {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), !collector.values.isEmpty || !collector.lists.isEmpty else { return nil }
        let name = collector.lists["crs:Name"]?.first ?? collector.values["crs:Name"]
        return Parsed(name: name, recipe: recipe(values: collector.values, lists: collector.lists))
    }

    /// Revelação guardada pelo Lightroom/Camera Raw no `.xmp` ao lado do RAW (sidecars só com estrelas não contam).
    static func sidecarRecipe(for url: URL) -> EditRecipe? {
        guard let data = try? Data(contentsOf: MetadataWriter.sidecarURL(for: url)), let parsed = parse(data),
              parsed.recipe != EditRecipe() else { return nil }
        return parsed.recipe
    }

    static func recipe(values: [String: String], lists: [String: [String]]) -> EditRecipe {
        var r = EditRecipe()
        func number(_ key: String) -> Double? {
            values["crs:\(key)"].flatMap { Double($0.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)) }
        }
        func set(_ key: String, _ path: WritableKeyPath<EditRecipe, Double>, scale: Double = 100, range: ClosedRange<Double> = -1...1) {
            if let value = number(key) { r[keyPath: path] = min(max(value / scale, range.lowerBound), range.upperBound) }
        }

        set("Exposure2012", \.exposure, scale: 1, range: -5...5)
        set("Contrast2012", \.contrast)
        set("Highlights2012", \.highlights)
        set("Shadows2012", \.shadows)
        set("Whites2012", \.whites)
        set("Blacks2012", \.blacks)
        set("Texture", \.texture)
        set("Clarity2012", \.clarity)
        set("Vibrance", \.vibrance)
        set("Saturation", \.saturation)
        set("IncrementalTemperature", \.temperature)
        set("IncrementalTint", \.tint, scale: 150)
        if let kelvin = number("Temperature") { r.temperature = min(max((kelvin - 5500) / 3000, -1), 1) }
        if let tint = number("Tint") { r.tint = min(max(tint / 150, -1), 1) }
        set("Sharpness", \.sharpness, scale: 150, range: 0...1)
        set("SharpenRadius", \.sharpenRadius, scale: 1, range: 0.5...3)
        set("SharpenEdgeMasking", \.sharpenMasking, range: 0...1)
        set("LuminanceSmoothing", \.noiseReduction, range: 0...1)
        set("ColorNoiseReduction", \.colorNoiseReduction, range: 0...1)
        set("PostCropVignetteAmount", \.vignette)
        set("GrainAmount", \.grain, range: 0...1)
        set("GrainSize", \.grainSize, range: 0...1)
        set("SplitToningShadowHue", \.shadowsHue, scale: 1, range: 0...360)
        set("SplitToningShadowSaturation", \.shadowsSaturation, range: 0...1)
        set("SplitToningHighlightHue", \.highlightsHue, scale: 1, range: 0...360)
        set("SplitToningHighlightSaturation", \.highlightsSaturation, range: 0...1)
        set("ColorGradeMidtoneHue", \.midtonesHue, scale: 1, range: 0...360)
        set("ColorGradeMidtoneSat", \.midtonesSaturation, range: 0...1)
        set("SplitToningBalance", \.gradingBalance)
        if values["crs:LensProfileEnable"] == "1" { r.lensCorrection = true }

        let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        for (index, band) in bands.enumerated() where index < r.hsl.count {
            if let value = number("HueAdjustment\(band)") { r.hsl[index].hue = min(max(value / 100, -1), 1) }
            if let value = number("SaturationAdjustment\(band)") { r.hsl[index].saturation = min(max(value / 100, -1), 1) }
            if let value = number("LuminanceAdjustment\(band)") { r.hsl[index].luminance = min(max(value / 100, -1), 1) }
        }

        let curves: [(String, CurveChannel)] = [("ToneCurvePV2012", .master), ("ToneCurvePV2012Red", .red), ("ToneCurvePV2012Green", .green), ("ToneCurvePV2012Blue", .blue)]
        for (key, channel) in curves {
            let points = (lists["crs:\(key)"] ?? []).compactMap { item -> CurvePoint? in
                let parts = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 2 else { return nil }
                return CurvePoint(x: min(max(parts[0] / 255, 0), 1), y: min(max(parts[1] / 255, 0), 1))
            }
            if points.count >= 2 { r.setCurve(points, for: channel) }
        }
        return r
    }

    /// Junta atributos `crs:` e elementos `crs:` (texto simples ou listas `rdf:li`).
    private final class Collector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var lists: [String: [String]] = [:]
        private var stack: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            for (key, value) in attributes where key.hasPrefix("crs:") {
                values[key] = value
            }
            stack.append(elementName)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stack.isEmpty { stack.removeLast() }
            if elementName == "rdf:li", let owner = stack.last(where: { $0.hasPrefix("crs:") }) {
                if !trimmed.isEmpty { lists[owner, default: []].append(trimmed) }
            } else if elementName.hasPrefix("crs:"), !trimmed.isEmpty, lists[elementName] == nil {
                values[elementName] = trimmed
            }
            text = ""
        }
    }
}

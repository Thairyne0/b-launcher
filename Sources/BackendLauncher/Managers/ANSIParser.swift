import Foundation

/// Segmento colorato di una riga di log (offset in unità UTF-16 sul testo PULITO).
struct ANSISpan: Equatable {
    let start: Int
    let length: Int
    /// Indice nella palette ANSI a 16 colori (30-37 → 0-7, 90-97 → 8-15), nil = solo bold.
    let colorIndex: Int?
    let bold: Bool
}

/// Parser SGR minimale per i log dei backend: colori foreground a 16 (+ i primi 16 della
/// modalità 256), bold, reset. Tutte le altre sequenze (cursore, OSC, truecolor, background)
/// vengono consumate e scartate — il testo pulito resta, senza escape grezzi.
/// Chiamato per RIGA COMPLETA (le sequenze non contengono newline): un escape spezzato
/// tra due chunk della pipe viene ricomposto dal buffering di LogStore prima del parse.
enum ANSIParser {
    static func parse(_ raw: String) -> (clean: String, spans: [ANSISpan]) {
        var clean = ""
        clean.reserveCapacity(raw.count)
        var spans: [ANSISpan] = []

        // Stato SGR corrente + inizio (in UTF-16 del testo pulito) del segmento aperto.
        var colorIndex: Int?
        var bold = false
        var segmentStart = 0
        var cleanUTF16Count = 0

        func closeSegment() {
            let length = cleanUTF16Count - segmentStart
            if length > 0, colorIndex != nil || bold {
                spans.append(ANSISpan(start: segmentStart, length: length,
                                      colorIndex: colorIndex, bold: bold))
            }
            segmentStart = cleanUTF16Count
        }

        let scalars = Array(raw.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "\u{1B}" else {
                clean.unicodeScalars.append(scalar)
                cleanUTF16Count += UTF16.width(scalar)
                i += 1
                continue
            }
            // ESC a fine stringa: scartato.
            guard i + 1 < scalars.count else { break }
            let next = scalars[i + 1]
            if next == "[" {
                // CSI: parametri fino al byte finale (0x40-0x7E). SGR se finale 'm'.
                var j = i + 2
                var params = ""
                while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                guard j < scalars.count else { break }  // CSI troncata a fine riga: scarta
                if scalars[j] == "m" {
                    closeSegment()
                    apply(sgrParams: params, colorIndex: &colorIndex, bold: &bold)
                }
                i = j + 1
            } else if next == "]" {
                // OSC: fino a BEL o ST (ESC \).
                var j = i + 2
                while j < scalars.count {
                    if scalars[j] == "\u{07}" { j += 1; break }
                    if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" {
                        j += 2; break
                    }
                    j += 1
                }
                i = j
            } else {
                i += 2  // altra sequenza ESC+byte: scartata
            }
        }
        closeSegment()
        return (clean, spans)
    }

    /// Applica una lista di parametri SGR ("1;33", "0", "38;5;12", …) allo stato corrente.
    private static func apply(sgrParams: String, colorIndex: inout Int?, bold: inout Bool) {
        var codes = sgrParams.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        if codes.isEmpty { codes = [0] }  // "ESC[m" equivale a reset
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: colorIndex = nil; bold = false
            case 1: bold = true
            case 22: bold = false
            case 30...37: colorIndex = code - 30
            case 90...97: colorIndex = code - 90 + 8
            case 39: colorIndex = nil
            case 38, 48:
                // Estese: 38;5;n (256) o 38;2;r;g;b (truecolor). Consuma gli argomenti;
                // solo fg 256 coi primi 16 indici viene mappato, il resto è ignorato.
                if index + 1 < codes.count, codes[index + 1] == 5 {
                    if code == 38, index + 2 < codes.count, (0...15).contains(codes[index + 2]) {
                        colorIndex = codes[index + 2]
                    }
                    index += 2
                } else if index + 1 < codes.count, codes[index + 1] == 2 {
                    index += 4
                }
            default: break  // background 40-47/100-107, corsivo, ecc.: ignorati
            }
            index += 1
        }
    }
}

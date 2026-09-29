import SwiftUI

/// One-colour sprites drawn on a square grid. `#` is a filled pixel.
struct PixelSprite {
    let rows: [String]

    var width: Int { rows.map(\.count).max() ?? 0 }
    var height: Int { rows.count }

    /// Terminal quadrant glyphs are twice as tall as they are wide, so a
    /// sprite traced from them doubles each row to keep its proportions.
    static func quadrants(_ rows: [String]) -> PixelSprite {
        PixelSprite(rows: rows.flatMap { [$0, $0] })
    }

    /// Clawd, as Claude Code 2.1 draws it in its welcome banner:
    ///
    ///      ▐▛███▛█
    ///     ▝▜██████▀
    ///      ▝▝   ▝▝
    static let claude = PixelSprite.quadrants([
        "..#############..",
        "..##.#######.##..",
        "#################",
        "..#############..",
        "..#.#.......#.#.."
    ])

    /// The `>_` that opens Codex's session banner.
    static let codex = PixelSprite(rows: [
        "##...........",
        ".##..........",
        "..##.........",
        "...##........",
        "....##.......",
        "...##........",
        "..##.........",
        ".##..........",
        "##.....######",
        ".......######"
    ])
}

/// One lime pixel marking work that is waiting for you. The solid ink edge
/// keeps it visible on paper; on ink it disappears into the background.
struct AttentionPixel: View {
    var body: some View {
        Rectangle()
            .fill(ElevateTheme.signal)
            .overlay(Rectangle().strokeBorder(ElevateTheme.onSignal, lineWidth: 1))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// Draws a sprite with whole-point pixels so it stays crisp at 1x and 2x.
struct PixelMark: View {
    let sprite: PixelSprite
    var pixel: CGFloat = 1.5
    var color: Color = ElevateTheme.ink

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for (y, row) in sprite.rows.enumerated() {
                for (x, cell) in row.enumerated() where cell == "#" {
                    path.addRect(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                        width: pixel, height: pixel))
                }
            }
            context.fill(path, with: .color(color))
        }
        .frame(width: CGFloat(sprite.width) * pixel, height: CGFloat(sprite.height) * pixel)
        .accessibilityHidden(true)
    }
}

import CoreGraphics
import Foundation

func runTabLabelTests() {
    func zone(_ length: CGFloat, slice: CGFloat, marker: CGFloat = 0) -> String {
        guard let zone = TabLabel.zone(textLength: length, tabHeight: 104, slice: slice, markerZone: marker) else { return "hidden" }
        return "\(Int(zone.minY))-\(Int(zone.maxY)) \(Int(zone.length))"
    }

    expect("whole tab: centred along all of it", zone(40, slice: 104), "0-104 40")
    expect("whole tab: a long label is shortened, not hidden", zone(130, slice: 104), "0-104 84")
    expect("whole tab: the marker takes the top", zone(40, slice: 104, marker: 16), "0-88 40")
    expect("slice: fits whole, centred in what shows", zone(40, slice: 70), "34-104 40")
    expect("slice: too long, as much of it as fits", zone(80, slice: 70), "34-104 62")
    expect("slice: the marker leaves less room", zone(80, slice: 70, marker: 16), "34-88 46")
    expect("slice: the minimum slice still shows the start", zone(60, slice: 22), "82-104 14")
    expect("slice: a short label in a thin slice, whole", zone(12, slice: 22), "82-104 12")
    expect("slice: too thin for even a letter", zone(60, slice: 20), "hidden")
    expect("slice: the marker can leave no room", zone(60, slice: 22, marker: 16), "hidden")
    expect("no label at all", zone(0, slice: 104), "hidden")
}

import SwiftUI

struct LCGPSLocationListView: View {
    @State private var locations: [String] = []
    @State private var newLocation = ""
    @State private var startLocation: String?
    @State private var endLocation: String?

    var body: some View {
        VStack {
            List {
                ForEach(locations, id: \.self) { location in
                    HStack {
                        Text(location)
                        Spacer()
                        if location == startLocation {
                            Image(systemName: "s.circle.fill")
                        }
                        if location == endLocation {
                            Image(systemName: "e.circle.fill")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if startLocation == nil {
                            startLocation = location
                        } else if endLocation == nil {
                            endLocation = location
                        } else {
                            startLocation = location
                            endLocation = nil
                        }
                    }
                }
                .onDelete(perform: delete)
            }

            HStack {
                TextField("New Location", text: $newLocation)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button(action: add) {
                    Text("Add")
                }
            }
            .padding()

            HStack {
                Button(action: {
                    startLocation = nil
                    endLocation = nil
                }) {
                    Text("Clear")
                }
                Spacer()
                Button(action: startSimulation) {
                    Text("Start Simulation")
                }
                .disabled(startLocation == nil || endLocation == nil)
            }
            .padding()
        }
        .navigationTitle("Saved Locations")
        .onAppear(perform: load)
    }

    private func load() {
        locations = UserDefaults.standard.stringArray(forKey: "LCGPSSavedLocations") ?? []
    }

    private func save() {
        UserDefaults.standard.set(locations, forKey: "LCGPSSavedLocations")
    }

    private func add() {
        guard !newLocation.isEmpty else { return }
        locations.append(newLocation)
        newLocation = ""
        save()
    }

    private func delete(at offsets: IndexSet) {
        locations.remove(atOffsets: offsets)
        save()
    }

    private func startSimulation() {
        guard let startLocation = startLocation, let endLocation = endLocation else { return }

        let startCoords = parseCoordinates(from: startLocation)
        let endCoords = parseCoordinates(from: endLocation)

        guard let start = startCoords, let end = endCoords else { return }

        var currentLocation = start
        let totalDistance = distance(from: start, to: end)
        let speed = 10.0 // meters per second
        let time = totalDistance / speed
        let steps = Int(time)
        let latStep = (end.latitude - start.latitude) / Double(steps)
        let lonStep = (end.longitude - start.longitude) / Double(steps)

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            currentLocation.latitude += latStep
            currentLocation.longitude += lonStep

            UserDefaults.standard.set(currentLocation.latitude, forKey: "LCGPSSpoofLatitude")
            UserDefaults.standard.set(currentLocation.longitude, forKey: "LCGPSSpoofLongitude")

            if distance(from: currentLocation, to: end) < speed {
                timer.invalidate()
            }
        }
    }

    private func parseCoordinates(from locationString: String) -> (latitude: Double, longitude: Double)? {
        let components = locationString.split(separator: ",")
        guard components.count == 2,
              let latitude = Double(components[0]),
              let longitude = Double(components[1]) else {
            return nil
        }
        return (latitude, longitude)
    }

    private func distance(from: (latitude: Double, longitude: Double), to: (latitude: Double, longitude: Double)) -> Double {
        let R = 6371e3 // metres
        let φ1 = from.latitude * .pi / 180 // φ, λ in radians
        let φ2 = to.latitude * .pi / 180
        let Δφ = (to.latitude - from.latitude) * .pi / 180
        let Δλ = (to.longitude - from.longitude) * .pi / 180

        let a = sin(Δφ / 2) * sin(Δφ / 2) +
                cos(φ1) * cos(φ2) *
                sin(Δλ / 2) * sin(Δλ / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return R * c // in metres
    }
}

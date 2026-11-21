"""Compile exact production discovery methods against in-memory doubles.

No HomeKit framework is imported. UUID/type constants are symbolic fixture
values; production name/category/writability/format maps remain unchanged.
"""
import hashlib
import json
from pathlib import Path
import re
import sys
root, out = map(Path, sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
paths = {key: root / path for key, path in {
    'manager': 'Sources/homeclaw/HomeKit/HomeKitManager.swift',
    'model': 'Sources/homeclaw/HomeKit/AccessoryModel.swift',
    'mapper': 'Sources/homeclaw/HomeKit/CharacteristicMapper.swift',
    'map': 'Sources/homeclaw/HomeKit/DeviceMap.swift',
    'discovery': 'Sources/homeclaw/Shared/ServiceDiscovery.swift',
}.items()}
sources = {key: path.read_text() for key, path in paths.items()}
def extract(source, signature):
    start = source.index(signature); pos = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}'); pos += 1
    return source[start:pos]
manager = [extract(sources['manager'], signature) for signature in [
    'func listAccessories(homeID:', 'func listRooms(homeID:', 'func searchAccessories(query:',
    'func deviceMap(homeID:', 'private func filteredHomes(homeID:',
    'private func filterAccessories(_ accessories:', 'private func isAccessoryAllowed(_ accessory:',
    'private func buildRoomZoneLookup(for targetHomes:',
]]
model = [extract(sources['model'], signature) for signature in [
    'static func accessorySummary(', 'static func discoveryServices(of accessory:',
    'static func roomSummary(', 'static func matterNodeIDString(', 'static func addMatterNodeID(',
    'private static func addBridgeMetadata(', 'static func computeHomeAppDisplayName(',
    'static func serviceLabelIndex(', 'static func ownDisplayAs(', 'static func displayAs(of service:',
    'static func displayAs(serviceType:', 'static func displayAsName(', 'static func isInterestingState(',
]]
start=sources['model'].index('    private static let serviceNamePreferredTypes:')
preferred=sources['model'][start:sources['model'].index('    ]', start)+5]
mapper=sources['mapper'][:sources['mapper'].index('    /// Parses a string value')]+'}\n'
mapper=mapper.replace('import HomeKit','import Foundation')
map_source=sources['map'].replace('import HomeKit','import Foundation')
constants=sorted(set(re.findall(r'\bHM(?:CharacteristicType|CharacteristicProperty|ServiceType|AccessoryCategoryType)[A-Z]\w*', mapper+'\n'+preferred+'\n'+'\n'.join(model))))
# Enum raw values are irrelevant to the boolean gang fixture, but retain distinct cases.
enums={'HMCharacteristicValueLockMechanismState':['unsecured','secured','jammed','unknown'],
       'HMCharacteristicValueDoorState':['open','closed','opening','closing','stopped'],
       'HMCharacteristicValueHeatingCooling':['off','heat','cool','auto']}
constant_source='\n'.join(f'let {name} = "fixture.{name}"' for name in constants)
constant_source+='\n'+'\n'.join('enum '+name+': Int { case '+', '.join(cases)+' }' for name,cases in enums.items())
(out/'Constants.swift').write_text(constant_source+'\n')
(out/'CharacteristicMapper.swift').write_text(mapper)
(out/'DeviceMap.swift').write_text(map_source)
(out/'Extracted.swift').write_text('import Foundation\n@MainActor final class FixtureManager {\n'
    +'let homes: [HMHome]; let cache = CharacteristicCache(); static let isDemoMode = false\n'
    +'init(_ homes: [HMHome]) { self.homes = homes }\n'
    +'func waitForReady() async {}\nfunc warmCache() async { fatalError("fixture must never refresh") }\n'
    +'\n'.join(manager)+'\n}\nenum AccessoryModel {\n'+preferred+'\n'+'\n'.join(model)+'\n}\n')
(out/'source-hashes.json').write_text(json.dumps({
    'sources':{str(paths[k].relative_to(root)):hashlib.sha256(v.encode()).hexdigest() for k,v in sources.items()},
    'extracted_methods':[hashlib.sha256(v.encode()).hexdigest() for v in manager+model],
},indent=2)+'\n')

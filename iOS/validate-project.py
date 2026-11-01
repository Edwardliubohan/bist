#!/usr/bin/env python3
"""Validate the checked-in build graph without requiring the Xcode app."""
import json
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(HERE / 'Bist.xcodeproj/project.pbxproj')]))
objects = project['objects']
ref_keys = {'fileRef', 'baseConfigurationReference', 'buildConfigurationList', 'productReference', 'mainGroup', 'productRefGroup', 'target', 'targetProxy', 'containerPortal', 'remoteGlobalIDString'}
list_keys = {'buildConfigurations', 'buildPhases', 'children', 'targets', 'files', 'dependencies'}
for key, value in objects.items():
    for name, item in value.items():
        if name in ref_keys:
            assert item in objects, (key, name, item)
        if name in list_keys:
            for ref in item:
                assert ref in objects, (key, name, ref)
    if value.get('isa') == 'PBXFileReference' and value.get('sourceTree') == 'SOURCE_ROOT':
        assert (HERE / value['path']).exists(), 'Missing file ' + value['path']

replica_sources = {str(path.resolve()) for path in (ROOT / 'Shared/Sources/BistSync').glob('*.swift')}
mac_sources = {str(path.resolve()) for path in (ROOT / 'Sources').glob('*.swift')}
for target in [value for value in objects.values() if value.get('isa') == 'PBXNativeTarget']:
    source_paths = set()
    for phase_ref in target['buildPhases']:
        phase = objects[phase_ref]
        if phase['isa'] == 'PBXSourcesBuildPhase':
            for build_ref in phase['files']:
                file_ref = objects[objects[build_ref]['fileRef']]
                source_paths.add(str((HERE / file_ref['path']).resolve()))
    if target['productType'] == 'com.apple.product-type.bundle.ui-testing':
        assert source_paths == {str(HERE / 'UITests/BistPhoneUITests.swift')}
        for ref in objects[target['buildConfigurationList']]['buildConfigurations']:
            settings = objects[ref]['buildSettings']
            assert settings['TEST_TARGET_NAME'] == 'Bist iPhone'
            assert settings['CODE_SIGN_ENTITLEMENTS'] == ''
        continue
    assert replica_sources <= source_paths, 'Missing replica source in ' + target['name']
    if target['name'] == 'Bist Mac':
        assert mac_sources <= source_paths, 'Missing Mac source'
    else:
        assert str(HERE / 'BistPhoneApp.swift') in source_paths
        assert str(ROOT / 'Sources/BistApp.swift') not in source_paths, 'Two app entry points in phone target'
    configurations = objects[target['buildConfigurationList']]['buildConfigurations']
    assert {objects[ref]['name'] for ref in configurations} == {'Debug', 'Release', 'CloudDebug', 'CloudRelease'}
    for ref in configurations:
        config = objects[ref]
        settings = config['buildSettings']
        info = plistlib.loads((HERE / settings['INFOPLIST_FILE']).read_bytes())
        if config['name'].startswith('Cloud'):
            entitlements = plistlib.loads((HERE / settings['CODE_SIGN_ENTITLEMENTS']).read_bytes())
            assert info['BistCloudKitContainer'] == '$(BIST_CLOUDKIT_CONTAINER)'
            assert entitlements['com.apple.developer.icloud-container-identifiers'] == ['$(BIST_CLOUDKIT_CONTAINER)']
        else:
            assert settings['CODE_SIGN_ENTITLEMENTS'] == ''
            assert info['BistCloudKitContainer'] == '', 'Local scheme must not start CloudKit'

schemes = list((HERE / 'Bist.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
assert len(schemes) == 4
for path in schemes:
    scheme = ET.parse(path).getroot()
    for ref in scheme.iter('BuildableReference'):
        assert ref.attrib['BlueprintIdentifier'] in objects
    testables = scheme.findall('TestAction/Testables/TestableReference')
    if path.stem == 'Bist iPhone':
        assert len(testables) == 1
        test_target = objects[testables[0].find('BuildableReference').attrib['BlueprintIdentifier']]
        assert test_target['productType'] == 'com.apple.product-type.bundle.ui-testing'
    else:
        assert not testables, 'UI tests must run against the local phone build'
    is_cloud = ' Cloud' in path.stem
    assert scheme.find('LaunchAction').attrib['buildConfiguration'] == ('CloudDebug' if is_cloud else 'Debug')
    assert scheme.find('ArchiveAction').attrib['buildConfiguration'] == ('CloudRelease' if is_cloud else 'Release')
print('PASS Xcode build graph, source coverage, local and Cloud configurations, and shared schemes')

#!/usr/bin/env python3
"""Regenerate the dependency-free Xcode project from shared Swift sources."""
from hashlib import sha1
from pathlib import Path
import json
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OBJECTS = {}

def ident(key):
    return sha1(key.encode()).hexdigest().upper()[:24]

def add(key, **value):
    ref = ident(key)
    OBJECTS[ref] = value
    return ref

def file_ref(path, kind):
    return add('file:' + path, isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='SOURCE_ROOT')

def build_ref(target, path, kind='sourcecode.swift'):
    return add('build:' + target + ':' + path, isa='PBXBuildFile', fileRef=file_ref(path, kind))

configs = ['Debug', 'Release', 'CloudDebug', 'CloudRelease']
config_refs = {name: file_ref('Configuration/' + ('Base' if name in ['Debug', 'Release'] else name) + '.xcconfig', 'text.xcconfig') for name in configs}
shared_names = ['BistCore.swift', 'LocalInbox.swift', 'NoteStore.swift', 'TaskViewState.swift', 'BistSync.swift', 'CloudKitSync.swift', 'SupabaseAuth.swift', 'SupabaseAccount.swift', 'SupabaseSync.swift', 'SupabaseSettings.swift']
shared = ['../Sources/' + name for name in shared_names]
replica = ['../' + str(path.relative_to(ROOT)) for path in sorted((ROOT / 'Shared/Sources/BistSync').glob('*.swift'))]
phone = ['BistPhoneApp.swift', 'PhoneTaskEditing.swift', 'PhoneViews.swift'] + shared + replica
mac = sorted(set(['../' + str(path.relative_to(ROOT)) for path in (ROOT / 'Sources').glob('*.swift')] + shared + replica))
platforms = {'phone': ('Bist iPhone', 'iOS', phone, 'Assets.xcassets'), 'mac': ('Bist Mac', 'macOS', mac, 'MacAssets.xcassets')}
products = []
targets = []

for target, (name, platform, sources, assets) in platforms.items():
    product = add('product:' + target, isa='PBXFileReference', explicitFileType='wrapper.application', includeInIndex='0', path=('bist.app' if target == 'mac' else 'bist iPhone.app'), sourceTree='BUILT_PRODUCTS_DIR')
    products.append(product)
    source_phase = add('sources:' + target, isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=[build_ref(target, path) for path in sources], runOnlyForDeploymentPostprocessing='0')
    resource_files = [build_ref(target, assets, 'folder.assetcatalog')]
    if target == 'mac':
        for path, kind in [('../scripts/bist-bobot.py', 'text.script.python'), ('../docs/BOBOT.md', 'net.daringfireball.markdown'), ('../Assets/bist-mark.svg', 'image.svg'), ('../Assets/bist-mark-animated.svg', 'image.svg')]:
            resource_files.append(build_ref(target, path, kind))
    resource_phase = add('resources:' + target, isa='PBXResourcesBuildPhase', buildActionMask='2147483647', files=resource_files, runOnlyForDeploymentPostprocessing='0')
    framework_phase = add('frameworks:' + target, isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
    build_configs = []
    for config in configs:
        cloud = config.startswith('Cloud')
        debug = config.endswith('Debug')
        settings = {
            'PRODUCT_NAME': 'bist' if target == 'mac' else 'bist iPhone',
            'PRODUCT_BUNDLE_IDENTIFIER': '$(BIST_MAC_BUNDLE_ID)' if target == 'mac' else '$(BIST_IPHONE_BUNDLE_ID)',
            'GENERATE_INFOPLIST_FILE': 'NO',
            'INFOPLIST_FILE': 'Configuration/Info-' + platform + ('-Cloud' if cloud else '') + '.plist',
            'CODE_SIGN_ENTITLEMENTS': ('Configuration/CloudKit-' + platform + '.entitlements') if cloud else '',
            'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
            'SDKROOT': 'macosx' if target == 'mac' else 'iphoneos',
            'SUPPORTED_PLATFORMS': 'macosx' if target == 'mac' else 'iphoneos iphonesimulator',
            'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if debug else '-O',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '$(inherited) DEBUG' if debug else '$(inherited)',
            'DEBUG_INFORMATION_FORMAT': 'dwarf' if debug else 'dwarf-with-dsym',
            'ENABLE_TESTABILITY': 'YES' if debug else 'NO',
            'SUPPORTS_MACCATALYST': 'NO',
        }
        if target == 'phone':
            settings.update(TARGETED_DEVICE_FAMILY='1', SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD='NO')
        else:
            settings.update(ARCHS='arm64', ENABLE_HARDENED_RUNTIME='YES', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'])
            if not cloud:
                settings.update(CODE_SIGN_IDENTITY='-', CODE_SIGN_STYLE='Manual')
        build_configs.append(add('config:' + target + ':' + config, isa='XCBuildConfiguration', baseConfigurationReference=config_refs[config], buildSettings=settings, name=config))
    config_list = add('configs:' + target, isa='XCConfigurationList', buildConfigurations=build_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    native = add('target:' + target, isa='PBXNativeTarget', buildConfigurationList=config_list, buildPhases=[source_phase, framework_phase, resource_phase], buildRules=[], dependencies=[], name=name, productName=name, productReference=product, productType='com.apple.product-type.application')
    targets.append(native)

# UI tests run only through the local iPhone scheme. They launch the app with
# an isolated UUID inside its own temporary container and use no CloudKit data.
ui_product = add('product:ui-tests', isa='PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex='0', path='BistPhoneUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products.append(ui_product)
ui_sources = add('sources:ui-tests', isa='PBXSourcesBuildPhase', buildActionMask='2147483647', files=[build_ref('ui-tests', 'UITests/BistPhoneUITests.swift')], runOnlyForDeploymentPostprocessing='0')
ui_frameworks = add('frameworks:ui-tests', isa='PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
ui_configs = []
for config in configs:
    ui_configs.append(add('config:ui-tests:' + config, isa='XCBuildConfiguration', baseConfigurationReference=config_refs['Debug'], buildSettings={
        'PRODUCT_NAME': 'BistPhoneUITests',
        'PRODUCT_BUNDLE_IDENTIFIER': '$(BIST_IPHONE_BUNDLE_ID).uitests',
        'GENERATE_INFOPLIST_FILE': 'YES',
        'CODE_SIGN_ENTITLEMENTS': '',
        'SDKROOT': 'iphoneos',
        'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
        'TARGETED_DEVICE_FAMILY': '1',
        'TEST_TARGET_NAME': 'Bist iPhone',
        'SWIFT_OPTIMIZATION_LEVEL': '-Onone',
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '$(inherited) DEBUG',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks'],
    }, name=config))
ui_config_list = add('configs:ui-tests', isa='XCConfigurationList', buildConfigurations=ui_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
ui_proxy = add('proxy:ui-tests', isa='PBXContainerItemProxy', containerPortal=ident('project'), proxyType='1', remoteGlobalIDString=ident('target:phone'), remoteInfo='Bist iPhone')
ui_dependency = add('dependency:ui-tests', isa='PBXTargetDependency', target=ident('target:phone'), targetProxy=ui_proxy)
ui_target = add('target:ui-tests', isa='PBXNativeTarget', buildConfigurationList=ui_config_list, buildPhases=[ui_sources, ui_frameworks], buildRules=[], dependencies=[ui_dependency], name='BistPhoneUITests', productName='BistPhoneUITests', productReference=ui_product, productType='com.apple.product-type.bundle.ui-testing')
targets.append(ui_target)

products_group = add('group:products', isa='PBXGroup', children=products, name='Products', sourceTree='<group>')
files = [key for key, value in OBJECTS.items() if value.get('isa') == 'PBXFileReference' and value.get('sourceTree') == 'SOURCE_ROOT']
main_group = add('group:root', isa='PBXGroup', children=files + [products_group], sourceTree='<group>')
project_configs = [add('project-config:' + config, isa='XCBuildConfiguration', buildSettings={'CLANG_ENABLE_MODULES':'YES', 'SWIFT_VERSION':'5.0'}, name=config) for config in configs]
project_config_list = add('project-configs', isa='XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
project = add('project', isa='PBXProject', attributes={'BuildIndependentTargetsInParallel':'YES', 'LastUpgradeCheck':'1500', 'TargetAttributes':{ident('target:ui-tests'):{'TestTargetID':ident('target:phone')}}}, buildConfigurationList=project_config_list, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings='0', knownRegions=['en', 'Base'], mainGroup=main_group, productRefGroup=products_group, projectDirPath='', projectRoot='', targets=targets)

def encode(value, indent=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t' * (indent + 1) + json.dumps(k) + ' = ' + encode(v, indent + 1) + ';\n' for k, v in value.items()) + '\t' * indent + '}'
    if isinstance(value, list):
        return '(\n' + ''.join('\t' * (indent + 1) + encode(v, indent + 1) + ',\n' for v in value) + '\t' * indent + ')'
    return json.dumps(str(value))

contents = '// !$*UTF8*$!\n' + encode({'archiveVersion':'1', 'classes':{}, 'objectVersion':'56', 'objects':OBJECTS, 'rootObject':project}) + '\n'
(HERE / 'Bist.xcodeproj/project.pbxproj').write_text(contents)

for target, (name, _, _, _) in platforms.items():
    for cloud in [False, True]:
        scheme_name = name + (' Cloud' if cloud else '')
        scheme = ET.Element('Scheme', LastUpgradeVersion='1500', version='1.7')
        build = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
        entries = ET.SubElement(build, 'BuildActionEntries')
        entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES', buildForProfiling='YES', buildForArchiving='YES', buildForAnalyzing='YES')
        reference = dict(BuildableIdentifier='primary', BlueprintIdentifier=ident('target:' + target), BuildableName='bist.app' if target == 'mac' else 'bist iPhone.app', BlueprintName=name, ReferencedContainer='container:Bist.xcodeproj')
        ET.SubElement(entry, 'BuildableReference', **reference)
        debug_config = 'CloudDebug' if cloud else 'Debug'
        release_config = 'CloudRelease' if cloud else 'Release'
        test_action = ET.SubElement(scheme, 'TestAction', buildConfiguration=debug_config, selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
        if target == 'phone' and not cloud:
            ui_reference = dict(BuildableIdentifier='primary', BlueprintIdentifier=ident('target:ui-tests'), BuildableName='BistPhoneUITests.xctest', BlueprintName='BistPhoneUITests', ReferencedContainer='container:Bist.xcodeproj')
            ui_entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='NO', buildForProfiling='NO', buildForArchiving='NO', buildForAnalyzing='YES')
            ET.SubElement(ui_entry, 'BuildableReference', **ui_reference)
            testables = ET.SubElement(test_action, 'Testables')
            testable = ET.SubElement(testables, 'TestableReference', skipped='NO', parallelizable='NO')
            ET.SubElement(testable, 'BuildableReference', **ui_reference)
        launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration=debug_config, selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', debugServiceExtension='internal', allowLocationSimulation='YES')
        runnable = ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0')
        ET.SubElement(runnable, 'BuildableReference', **reference)
        profile = ET.SubElement(scheme, 'ProfileAction', buildConfiguration=release_config, shouldUseLaunchSchemeArgsEnv='YES', savedToolIdentifier='', useCustomWorkingDirectory='NO', debugDocumentVersioning='YES')
        runnable = ET.SubElement(profile, 'BuildableProductRunnable', runnableDebuggingMode='0')
        ET.SubElement(runnable, 'BuildableReference', **reference)
        ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration=debug_config)
        ET.SubElement(scheme, 'ArchiveAction', buildConfiguration=release_config, revealArchiveInOrganizer='YES')
        ET.indent(scheme)
        (HERE / 'Bist.xcodeproj/xcshareddata/xcschemes' / (scheme_name + '.xcscheme')).write_bytes(ET.tostring(scheme, encoding='utf-8', xml_declaration=True) + b'\n')
print('Generated Bist.xcodeproj with iPhone and Mac targets')

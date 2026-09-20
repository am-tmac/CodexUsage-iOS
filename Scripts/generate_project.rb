require 'xcodeproj'
require 'fileutils'
root = File.expand_path('..', __dir__)
Dir.chdir(root)
p = Xcodeproj::Project.new('CodexUsage.xcodeproj')
public_config = p.main_group.new_file('Configuration/Public.xcconfig')
app = p.new_target(:application, 'CodexUsage', :ios, '17.0')
widget = p.new_target(:app_extension, 'CodexUsageWidget', :ios, '17.0')
tests = p.new_target(:unit_test_bundle, 'CodexUsageTests', :ios, '17.0')
shared = Dir['Shared/*.swift']
[[app, shared + Dir['App/*.swift']], [widget, shared + Dir['Widget/*.swift']], [tests, Dir['Tests/*.swift']]].each do |target, files|
  files.each { |file| target.source_build_phase.add_file_reference(p.main_group.new_file(file)) }
end
app.resources_build_phase.add_file_reference(p.main_group.new_file('App/Assets.xcassets'))
app.add_dependency(widget)
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(widget.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
tests.add_dependency(app)
[app, widget, tests].each do |target|
  target.build_configurations.each do |config|
    config.base_configuration_reference = public_config
    s = config.build_settings
    s['SWIFT_VERSION'] = '5.0'
    s['TARGETED_DEVICE_FAMILY'] = '1'
    s['CODE_SIGN_STYLE'] = 'Automatic'
    s['DEVELOPMENT_TEAM'] = ''
    # Override one root ID for re-sign builds; never give app and extension the same ID.
    s['CODEX_APP_BUNDLE_IDENTIFIER'] = 'com.personal.CodexUsage'
    s['PRODUCT_BUNDLE_IDENTIFIER'] = target == widget ? '$(CODEX_APP_BUNDLE_IDENTIFIER).Widget' : (target == app ? '$(CODEX_APP_BUNDLE_IDENTIFIER)' : '$(CODEX_APP_BUNDLE_IDENTIFIER).Tests')
    s['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = ''
    s['CURRENT_PROJECT_VERSION'] = '17'
    s['MARKETING_VERSION'] = '2.0'
    s['GENERATE_INFOPLIST_FILE'] = 'YES'
    s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
    s['APP_GROUP_IDENTIFIER'] = 'group.com.personal.CodexUsage'
    s['KEYCHAIN_GROUP_IDENTIFIER'] = 'com.personal.CodexUsage.shared'
    s['ANTIGRAVITY_CLIENT_ID'] = ''
    s['ANTIGRAVITY_CLIENT_SECRET'] = ''
    s['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
    s['SUPPORTS_MACCATALYST'] = 'NO'
    if target == tests
      s['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/CodexUsage.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CodexUsage'
      s['BUNDLE_LOADER'] = '$(TEST_HOST)'
      s['PRODUCT_MODULE_NAME'] = 'CodexUsageTests'
    else
      s['INFOPLIST_FILE'] = target == app ? 'App/Info.plist' : 'Widget/Info.plist'
      s['CODE_SIGN_ENTITLEMENTS'] = 'Configuration/Shared.entitlements'
      s['PRODUCT_MODULE_NAME'] = target == app ? 'CodexUsageCore' : 'CodexUsageWidget'
      s['INFOPLIST_KEY_CFBundleDisplayName'] = target == app ? 'Codex 用量' : 'Codex 额度'
      s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
    end
  end
end
app.build_configurations.each { |c| c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'; c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'; c.build_settings['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait' }
widget.build_configurations.each { |c| c.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'; c.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) CODEX_WIDGET'; c.build_settings['SKIP_INSTALL'] = 'YES' }
p.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(p.path, 'CodexUsage', true)
puts 'Generated CodexUsage.xcodeproj'

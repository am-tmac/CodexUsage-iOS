# Adds new sources to the existing project without regenerating it (the generator would
# rewrite signing settings). Mirrors how generate_project.rb lays out file references:
# Shared/*.swift compiles into App + Widget, App/*.swift into the App only.
require 'xcodeproj'
root = File.expand_path('..', __dir__)
Dir.chdir(root)
p = Xcodeproj::Project.open('CodexUsage.xcodeproj')
app = p.targets.find { |t| t.name == 'CodexUsage' }
widget = p.targets.find { |t| t.name == 'CodexUsageWidget' }
plan = { 'Shared/CardOrder.swift' => [app, widget], 'Shared/Antigravity.swift' => [app, widget], 'App/ExtraProviderPanels.swift' => [app], 'App/AntigravityLogin.swift' => [app] }
existing = p.files.map(&:path)
plan.each do |path, targets|
  ref = existing.include?(path) ? p.files.find { |f| f.path == path } : p.main_group.new_file(path)
  targets.each do |target|
    already = target.source_build_phase.files_references.map(&:path)
    next if already.include?(path)
    target.source_build_phase.add_file_reference(ref)
    puts "added #{path} -> #{target.name}"
  end
end
p.save
puts 'saved'

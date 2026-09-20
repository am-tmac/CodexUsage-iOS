# 从现有工程移除源文件（不重跑生成器，避免覆盖签名设置）。
require 'xcodeproj'
root = File.expand_path('..', __dir__)
Dir.chdir(root)
p = Xcodeproj::Project.open('CodexUsage.xcodeproj')
paths = ARGV
abort('usage: ruby Scripts/remove_sources.rb <path> [path...]') if paths.empty?
paths.each do |path|
  refs = p.files.select { |f| f.path == path }
  if refs.empty?
    puts "skip (not referenced): #{path}"
    next
  end
  refs.each do |ref|
    p.targets.each do |target|
      phase = target.source_build_phase
      phase.files.select { |bf| bf.file_ref == ref }.each do |bf|
        phase.remove_build_file(bf)
        puts "removed #{path} from #{target.name}"
      end
    end
    ref.remove_from_project
  end
end
p.save
puts 'saved'

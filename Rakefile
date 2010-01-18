require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "gcalendar"
    gem.summary = %Q{Google calendar library}
    gem.description = %Q{Yet another google calendar library.  Uses GData for api access and ri_cal for properly parsing RFC2445 (recurrences)}
    gem.email = "eddyhkim@gmail.com"
    gem.homepage = "http://github.com/edk/gcalendar"
    gem.authors = ["Eddy Kim"]
    gem.requirements << "gdata, a library to access the Google Data API"
    gem.requirements << "ri_cal, a library to read and manipulate RFC2445 entitites"
    gem.add_dependency 'gdata', '>= 1.1.1'
    gem.add_dependency 'ri_cal'
    
    # gem is a Gem::Specification... see http://www.rubygems.org/read/chapter/20 for additional settings
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: gem install jeweler"
end

require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/test_*.rb'
  test.verbose = true
end

begin
  require 'rcov/rcovtask'
  Rcov::RcovTask.new do |test|
    test.libs << 'test'
    test.pattern = 'test/**/test_*.rb'
    test.verbose = true
  end
rescue LoadError
  task :rcov do
    abort "RCov is not available. In order to run rcov, you must: sudo gem install spicycode-rcov"
  end
end

task :test => :check_dependencies

task :default => :test

require 'rake/rdoctask'
Rake::RDocTask.new do |rdoc|
  version = File.exist?('VERSION') ? File.read('VERSION') : ""

  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "gcalendar #{version}"
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end

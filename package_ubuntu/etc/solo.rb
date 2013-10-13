config_file = ENV['MASTER_CHEF_CONFIG']

puts "Using config file #{config_file}"

raise "Please specify config file with env var MASTER_CHEF_CONFIG" unless config_file
raise "File not found #{config_file}" unless File.exists? config_file

require 'tempfile'

config = JSON.load(File.read(config_file))

run_list = ["recipe[master_chef::init]"] + (ENV['OVERRIDE_RUN_LIST'] ? ENV['OVERRIDE_RUN_LIST'].split(",") : config["run_list"])
json_file = File.join(Dir::tmpdir, "chef_#{Process.pid}_#{Time.now.to_i}")
File.open(json_file, 'w') {|io| io.write JSON.dump({"run_list" => run_list})}
Kernel.at_exit do
  File.unlink json_file if File.exists? json_file
end

ENV['MASTER_CHEF_CONFIG'] = File.expand_path(config_file)

def exec_local cmd
  begin
    abort "#{cmd} failed. Aborting..." unless system cmd
  rescue
    abort "#{cmd} failed. Aborting..."
  end
end

def capture_local cmd
  begin
    result = %x{#{cmd}}
    abort "#{cmd} failed. Aborting..." unless $? == 0
    result
  rescue
    abort "#{cmd} failed. Aborting..."
  end
end

cookbooks = []
roles = []

folders = {}

if config["repos"]["git"]

  git_cache_directory = ENV["GIT_CACHE_DIRECTORY"] || "/opt/master-chef/var/git_repos"
  exec_local "mkdir -p #{git_cache_directory} && chmod -R go-rwx #{git_cache_directory}"

  git_tag_override_file = config_file + ".git_tag_override"
  if ENV["GIT_TAG_OVERRIDE"]
    repos = {}
    ENV["GIT_TAG_OVERRIDE"].split(",").each do |k|
      repos[$1] = $2 if k =~ /^(.*)=(.*)$/
    end
    File.open(git_tag_override_file, "w") {|io| io.write(JSON.pretty_generate(repos))}
  end
  git_tag_override = {}
  git_tag_override = JSON.load(File.read(git_tag_override_file)) if File.exists? git_tag_override_file
  config["repos"]["git"].each do |url|
    name = File.basename(url).gsub(/:/, '_')
    name = "#{$1}_#{name}" if url.match(/^(https?)/)
    target = File.join(git_cache_directory, name)
    if ENV["NO_UPDATE"]
      verb = "Using local"
    else
      if File.exists? target
        verb = "Updating"
        exec_local "cd #{target} && git fetch -q origin && git fetch --tags -q origin"
      else
        verb = "Cloning"
        exec_local "cd #{git_cache_directory} && git clone -q #{url} #{name} && cd #{target} && git checkout -q -b deploy"
      end
    end
    branch_target = git_tag_override[url] || "master"
    sha = capture_local("cd #{target} && git show-ref").split("\n").find do |l|
      l =~ /refs\/remotes\/origin\/#{branch_target}$/ || l =~ /refs\/tags\/#{branch_target}$/
    end
    if sha
      sha = sha.split(" ")[0]
    else
      sha = branch_target
    end
    puts "#{verb} from #{url}, using branch #{branch_target}, commit #{sha}"
    exec_local "cd #{target} && git reset -q --hard #{sha} && git clean -q -d -x -f"
    folders[url] = sha
    cookbook = File.join(target, "cookbooks")
    cookbooks << cookbook if File.exists? cookbook
    role = File.join(target, "roles")
    roles << role if File.exists? role
  end
end

if config["repos"]["local_path"]
  config["repos"]["local_path"].each do |target|
    folders[target] = "local"
    puts "Using folder #{target}"
    cookbook = File.join(target, "cookbooks")
    cookbooks << cookbook if File.exists? cookbook
    role = File.join(target, "roles")
    roles << role if File.exists? role
  end
end

if ENV['REPOS_STATUS_FILE']
  File.open(ENV['REPOS_STATUS_FILE'], 'w') {|io| io.write(JSON.dump(folders))}
end

if ENV['http_proxy']
  ENV['BACKUP_http_proxy'] = ENV['http_proxy']
  ENV.delete 'http_proxy'
end

if ENV['https_proxy']
  ENV['BACKUP_https_proxy'] = ENV['https_proxy']
  ENV.delete 'https_proxy'
end

puts "************************* Master chef SOLO *************************"
puts "Hostname : #{`hostname`}"
puts "Repos : #{config["repos"].inspect}"
puts "Run list : #{run_list.inspect}"
puts "Cookbooks path : #{cookbooks.inspect}"
puts "Roles path : #{roles.inspect}"
puts "********************************************************************"


log_level (ENV['CHEF_LOG_LEVEL'] || 'info').to_sym
log_location STDOUT
json_attribs json_file
cookbook_path cookbooks
role_path roles

var_chef = ENV["VAR_CHEF"] || "/opt/chef/var"
file_cache_path "#{var_chef}/cache"
file_backup_path "#{var_chef}/backup"
openid_cstore_path "#{var_chef}/openid/cstore"

verbose_logging false
Mixlib::Log::Formatter.show_time = false

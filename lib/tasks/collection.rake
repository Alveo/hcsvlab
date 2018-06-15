require File.dirname(__FILE__) + '/collection_helper.rb'

namespace :collection do

  #
  # Change the owner of a single collection
  #
  desc "Change the owner of a collection"
  task :change_owner, [:collection_name, :owner_email] => :environment do |task, args|

    collection_name = args.collection_name
    owner_email = args.owner_email

    if (collection_name.nil? || owner_email.nil?)
      puts "Usage: rake collection:change_owner[collection_name,owner_email]"
      exit 1
    end

    unless collection = Collection.where(:name => collection_name).first
      puts "Collection not found (by name)"
      exit 1
    end

    unless owner = User.where(:email => owner_email).first
      puts "Owner not found (by email)"
      exit 1
    end

    collection.owner = owner
    if collection.save
      puts "Owner changed to #{owner.email} (User ##{owner.id})"
      exit 0
    else
      puts "Error saving"
      exit 1
    end
  end

  #
  # Check collection data integrity. All data source (DB/Sesame/Solr) must be consistent. Generate report (log) for further action.
  #
  desc "Check collection data integrity"
  task :check_integrity => [:environment] do
    collection_name = ARGV.last

    puts "Start checking collection '#{collection_name}'..."

    if (collection_name.nil?)
      puts "Usage: rake collection:check_integrity collection_name".red
      exit 1
    end

    unless collection = Collection.where(:name => collection_name).first
      puts "Collection '#{collection_name}' not found (by name)".red
      exit 1
    end

    rlt = check_integrity(collection_name)

    puts rlt.green
    exit 0
  end

  #
  # Check item data integrity. All item data (DB/Sesame) must be consistent. Generate output file (<input file>.out) for further action.
  #
  desc "Check item data integrity"
  task :check_item => [:environment] do
    file_name = ARGV.last

    puts "Start checking file '#{file_name}'..."

    if (file_name.nil?) || !File.file?(file_name)
      puts "Usage: rake collection:check_item file_name \nFile format: one item handle per line".red
      exit 1
    end

    rlt = check_item(file_name)

    puts rlt.green
    exit 0
  end

  #
  # Fix inconsistent item. All item data (DB/Sesame/Solr) must be consistent. Generate log for further action.
  #
  desc "Fix inconsistent item"
  task :fix_item => [:environment] do
    file_name = ARGV.last

    puts "Start checking file '#{file_name}'..."

    if (file_name.nil?) || !File.file?(file_name)
      puts "Usage: rake collection:fix_item file_name \nFile format: one item handle per line".red
      exit 1
    end

    rlt = fix_item(file_name)

    puts rlt.green
    exit 0
  end

  #
  # Check missing speaker data (austalk). Generate CSV for further action.
  #
  desc "Check missing speaker data"
  task :check_speaker_data => [:environment] do
    file_name = ARGV.last

    puts "Start reading input file '#{file_name}'..."

    if (file_name.nil?) || !File.file?(file_name)
      puts "Usage: rake collection:check_speaker_data file_name \nFile format: CSV (prefix, university, source path)".red
      exit 1
    end

    rlt = check_speaker_data("austalk", file_name)

    puts rlt.green
    exit 0
  end

end

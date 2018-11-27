require 'spec_helper'

# Specs in this file have access to a helper object that includes
# the ContributionsHelper. For example:
#
# describe ContributionsHelper do
#   describe "string concat" do
#     it "concats two strings with spaces" do
#       expect(helper.concat_strings("this","that")).to eq("this that")
#     end
#   end
# end
RSpec.describe ContributionsHelper, :type => :helper do
  # pending "add some examples to (or delete) #{__FILE__}"

  let(:owner) {FactoryGirl.create(:user_data_owner)}
  let(:collection) {FactoryGirl.create(:collection, owner: owner, name: "family_1")}
  let(:item) {FactoryGirl.create(:item, collection: collection, handle: "#{collection.name}:kid_1")}
  let(:contribution) {FactoryGirl.create(:contribution, collection: collection)}

  after do
    FileUtils.rm_r(APP_CONFIG["contrib_dir"])
    FileUtils.mkdir_p(APP_CONFIG["contrib_dir"])
  end

  describe "test entry_names_from_zip" do
    context "when zip file contains validated file" do
      it "returns entry names from zip file" do
        zip_file = "test/samples/contributions/contrib_doc.zip"
        rlt = ContributionsHelper.entry_names_from_zip(zip_file)

        expect(rlt.is_a?(Array)).to be_true
      end
    end

    context "when zip file is invalid or damaged" do
      it "raises exception" do
        zip_file = "test/samples/austalk.n3"
        rlt = ContributionsHelper.entry_names_from_zip(zip_file)
        expect(rlt).to eq("Zip end of central directory signature not found")
      end
    end

    context "when zip file is not found" do
      it "raises exception" do
        zip_file = "test/samples/contributions/contrib_doc.zip.not_exists"
        rlt = ContributionsHelper.entry_names_from_zip(zip_file)
        expect(rlt).to end_with("not found")
      end
    end
  end

  describe "test preview_import" do
    let!(:doc_1) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Rodney.wav")}
    let!(:doc_2) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Isaac.wav")}
    let!(:doc_3) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Phoebe.wav")}

    context "when zip contains all good files" do
      it "returns all success" do
        #   prepare zip
        src = "#{Rails.root}/test/samples/contributions/contrib_doc.zip"
        dest = ContributionsHelper.contribution_import_zip_file(contribution)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(src, dest)

        rlt = ContributionsHelper.preview_import(contribution)

        rlt.each do |row|
          expect(row[:message]).to be_nil
        end
      end
    end

    context "when zip contains bad file" do
      it "returns error result - not found" do
        #   prepare zip
        src = "#{Rails.root}/test/samples/contributions/contrib_doc.error.zip"
        dest = ContributionsHelper.contribution_import_zip_file(contribution)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(src, dest)

        rlt = ContributionsHelper.preview_import(contribution)

        error_not_found = false

        rlt.each do |row|
          if !row[:message].nil? && row[:message].include?("no item/document found to associate with")
            error_not_found = true
          end
        end

        expect(error_not_found).to be_true
      end
    end

  end

  describe "test unzip" do

    let(:zip_file) {ContributionsHelper.contribution_import_zip_file(contribution)}
    let(:unzip_dir) {File.join(File.dirname(zip_file), File.basename(zip_file, ".zip"))}

    after do
      #   clean up
      FileUtils.rm_r unzip_dir
    end

    context "with valid zip file" do
      let(:src) {"#{Rails.root}/test/samples/contributions/contrib_doc.zip"}
      let(:dest) {ContributionsHelper.contribution_import_zip_file(contribution)}

      it "returns array of file full path" do
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(src, dest)
        rlt = ContributionsHelper.unzip(dest, unzip_dir)

        if !rlt.is_a? String

          rlt.each do |f|
            expect(File.exists?(f[:dest_name])).to be_true
          end

        end
      end
    end
  end

  describe "test import" do
    let!(:doc_1) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Rodney.wav")}
    let!(:doc_2) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Isaac.wav")}
    let!(:doc_3) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Phoebe.wav")}

    context "when zip is not present" do
      it "returns zip file not found" do
        rlt = ContributionsHelper.import(contribution)

        expect(rlt.end_with?("not found")).to be_true
      end
    end

    context "when zip is present and valid" do
      it "returns string message indicates success" do
        src = "#{Rails.root}/test/samples/contributions/contrib_doc.zip"
        dest = ContributionsHelper.contribution_import_zip_file(contribution)
        FileUtils.mkdir_p(ContributionsHelper.contribution_dir(contribution))
        FileUtils.cp(src, dest)

        rlt = ContributionsHelper.import(contribution)
        expect(rlt.end_with?("document(s) imported.")).to be_true
      end
    end

    context "when zip is error" do
      it "returns string message indicates failure" do
        src = "#{Rails.root}/test/samples/contributions/contrib_doc.error.zip"
        dest = ContributionsHelper.contribution_import_zip_file(contribution)
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(src, dest)

        rlt = ContributionsHelper.import(contribution)
        expect(rlt.start_with?("import failed")).to be_true
      end
    end
  end

  describe "test contribution_dir" do
    context "when contribution is valid" do
      it "returns valid directory" do
        dir = File.join(APP_CONFIG["contrib_dir"], contribution.collection.name, contribution.id.to_s)
        rlt = ContributionsHelper.contribution_dir(contribution)

        expect(rlt).to eq(dir)
      end
    end

    context "when contribution is nil" do
      it "returns nil" do
        contribution = nil
        rlt = ContributionsHelper.contribution_dir(contribution)

        expect(rlt.nil?).to be_true
      end
    end

    context "when contribution is invalid, collection is nil" do
      it "returns nil" do
        contribution.collection = nil
        rlt = ContributionsHelper.contribution_dir(contribution)

        expect(rlt.nil?).to be_true
      end
    end
  end


  describe "test validate_contribution_file" do
    let!(:doc_1) {FactoryGirl.create(:document, item: item, file_name: "Rodney.wav")}
    let!(:doc_2) {FactoryGirl.create(:document, item: item, file_name: "Isaac.wav")}
    let!(:doc_3) {FactoryGirl.create(:document, item: item, file_name: "Phoebe.wav")}
    let!(:doc_4) {FactoryGirl.create(:document, item: item, file_name: "Rodney_123_abc.wav")}

    let!(:item_bak) {FactoryGirl.create(:item, collection: collection, handle: "#{collection.name}:kid_2")}
    let!(:doc_bak_1) {FactoryGirl.create(:document, item: item_bak, file_name: "#{item.get_name}.wav")}

    context "with type:delimiter" do
      it "delimiter '-' and field 1 and item name can be extracted, then file is valid" do
        file = "#{item.get_name}-test.txt"
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file)

        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:message]).to be_nil
        expect(rlt[:dest_file]).to eq(file)
      end

      it "delimiter '-' and field 1 but item name cannot be extracted, then file is invalid" do
        file = "Rodney.ps"
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file)

        expect(rlt[:item_handle]).to be_nil
        expect(rlt[:message]).to eq("no item/document found to associate with '#{file}'")
        expect(rlt[:dest_file]).to be_nil
      end

      it "delimiter '-' and field 2 and item name can be extracted, then file is valid" do
        file = "test-#{item.get_name}.txt"
        sep = {:type => 'delimiter', :delimiter => '-', :field => 2}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:message]).to be_nil
        expect(rlt[:dest_file]).to eq(file)
      end

      it "delimiter '-' and field 999 but item name cannot be extracted, then file is invalid" do
        file = "test-#{item.get_name}.txt"
        sep = {:type => 'delimiter', :delimiter => '-', :field => 999}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to be_nil
        expect(rlt[:message]).to eq("no item/document found to associate with '#{file}'")
        expect(rlt[:dest_file]).to be_nil
      end

      it "delimiter '-' and field -1 but item name cannot be extracted, then file is invalid" do
        file = "test-#{item.get_name}.txt"
        sep = {:type => 'delimiter', :delimiter => '-', :field => -1}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to be_nil
        expect(rlt[:message]).to eq("no item/document found to associate with '#{file}'")
        expect(rlt[:dest_file]).to be_nil
      end

      it "delimiter '-' and field 'a' but item name cannot be extracted, then file is invalid" do
        file = "test-#{item.get_name}.txt"
        sep = {:type => 'delimiter', :delimiter => '-', :field => 'a'}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to be_nil
        expect(rlt[:message]).to eq("no item/document found to associate with '#{file}'")
        expect(rlt[:dest_file]).to be_nil
      end

      it "delimiter '-' and field 2 but item name cannot be extracted, then file is invalid" do
        file = "test-123-#{item.get_name}.txt"
        sep = {:type => 'delimiter', :delimiter => '-', :field => 2}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to be_nil
        expect(rlt[:message]).to eq("no item/document found to associate with '#{file}'")
        expect(rlt[:dest_file]).to be_nil
      end

      it "delimiter '.' and field 1 and item name can be extracted, then file is valid" do
        file = "#{item.get_name}.Rodney.txt"
        sep = {:type => 'delimiter', :delimiter => '.', :field => 1}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:message]).to be_nil
        expect(rlt[:dest_file]).to eq(file)
        expect(rlt[:document_file_name]).to eq([])
      end
    end

    context "with type:offset" do
      it "offset is correct and item name can be extracted, then file is valid" do
        file = "#{item.get_name}_Rodney.txt"
        sep = {:type => 'offset', :offset => item.get_name().length}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:message]).to be_nil
        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:dest_file]).to eq(file)
        expect(rlt[:document_file_name]).to eq([])
      end

      it "offset is wrong and item name cannot be extracted, then file is invalid" do
        file = "#{item.get_name}_Rodney.txt"
        sep = {:type => 'offset', :offset => item.get_name().length + 1}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to be_nil
        expect(rlt[:message]).to eq("no item/document found to associate with '#{file}'")
        expect(rlt[:dest_file]).to be_nil
      end
    end

    context "with type:item" do
      it "file base name is the same as item name, then file is valid" do
        file = "#{item.get_name}.trs"
        sep = {:type => 'item'}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:message]).to be_nil
        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:dest_file]).to eq(file)
      end

      it "file base name is not the same as item name, then file is invalid" do
        file = "kid_1_abc.trs"
        sep = {:type => 'item'}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to be_nil
        expect(rlt[:message]).to eq("no item/document found to associate with '#{file}'")
        expect(rlt[:dest_file]).to be_nil
      end
    end

    context "with type:doc" do
      it "file base name is the same as doc name, then file is valid" do
        file = "Rodney.test"
        sep = {:type => 'doc'}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:message]).to be_nil
        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:dest_file]).to eq(file)
        expect(rlt[:document_file_name]).to eq(["Rodney.wav", "Rodney_123_abc.wav"])
      end

      it "doc name is prefix of file base name, then file is valid" do
        file = "Rodney_123.test"
        sep = {:type => 'doc'}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:message]).to be_nil
        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:dest_file]).to eq(file)
        expect(rlt[:document_file_name]).to eq(["Rodney_123_abc.wav"])
      end

      it "file name has no relationship with doc name, then file is invalid" do
        file = "abc.wav"
        sep = {:type => 'doc'}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:item_handle]).to be_nil
        expect(rlt[:message]).to eq("no item/document found to associate with '#{file}'")
        expect(rlt[:dest_file]).to be_nil
      end
    end

    context "same name collection-document found" do
      it "returns new file name with rename mode" do
        file = "#{doc_1.file_name}"
        sep = {:type => 'doc'}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expected_name = "Rodney-c#{contribution.id}.wav"
        expect(rlt[:message]).to eq("Duplicated document found[#{doc_1.file_name}]. New file would be renamed as '#{expected_name}'.")
        expect(rlt[:mode]).to eq("rename")
        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:dest_file]).to eq(expected_name)
        expect(rlt[:document_file_name]).to eq(["#{doc_1.file_name}", "#{doc_4.file_name}"])
      end
    end

    context "same name contribution-document (same contribution) found " do
      let!(:doc_5) {FactoryGirl.create(:document, item: item, file_name: "Rodney.txt")}
      let!(:cm_1) {FactoryGirl.create(:contribution_mapping, contribution: contribution, document: doc_5)}

      it "returns same file name with overwrite mode" do
        file = "#{doc_5.file_name}"
        sep = {:type => 'doc'}
        rlt = ContributionsHelper.validate_contribution_file(contribution.id, file, sep)

        expect(rlt[:message]).to eq("Duplicated document found[#{file}]. Existing file would be overwritten as '#{file}'.")
        expect(rlt[:mode]).to eq("overwrite")
        expect(rlt[:item_handle]).to eq(item.handle)
        expect(rlt[:dest_file]).to eq(file)
        expect(rlt[:document_file_name]).to eq(["#{file}", "#{doc_1.file_name}", "#{doc_4.file_name}"])
      end
    end
  end

  describe "test export_as_zip" do
    let!(:doc_1) {FactoryGirl.create(:document, item: item, file_name: "Rodney.wav")}
    let!(:doc_2) {FactoryGirl.create(:document, item: item, file_name: "Isaac.wav")}
    let!(:doc_3) {FactoryGirl.create(:document, item: item, file_name: "Phoebe.wav")}

    let!(:contrib_dir) {ContributionsHelper.contribution_dir(contribution)}
    let!(:contrib_doc_1) do
      FactoryGirl.create(
        :document,
        item: item,
        file_name: "#{item.get_name}-Rodney.ps",
        file_path: "#{contrib_dir}/#{item.get_name}-Rodney.ps")
    end
    let!(:contrib_doc_2) do
      FactoryGirl.create(
        :document,
        item: item,
        file_name: "#{item.get_name}-Isaac.txt",
        file_path: "#{contrib_dir}/#{item.get_name}-Isaac.txt")
    end
    let!(:contrib_doc_3) do
      FactoryGirl.create(
        :document,
        item: item,
        file_name: "#{item.get_name}-Phoebe.txt",
        file_path: "#{contrib_dir}/#{item.get_name}-Phoebe.txt")
    end

    let!(:contrib_mapping_1) {FactoryGirl.create(:contribution_mapping, contribution: contribution, document: contrib_doc_1)}
    let!(:contrib_mapping_2) {FactoryGirl.create(:contribution_mapping, contribution: contribution, document: contrib_doc_2)}
    let!(:contrib_mapping_3) {FactoryGirl.create(:contribution_mapping, contribution: contribution, document: contrib_doc_3)}

    before(:each) do
      src_dir = "#{Rails.root}/test/samples/contributions/contrib_doc"

      # collection document file
      files = [doc_1.file_name, doc_2.file_name, doc_3.file_name].map{|f| File.join(src_dir, f)}
      dest_dir = "/data/collections/#{item.handle.split(':').first}/"
      FileUtils.mkdir_p(dest_dir)
      FileUtils.cp(files, dest_dir)

      # contribution document file
      files = [contrib_doc_1.file_name, contrib_doc_2.file_name, contrib_doc_3.file_name].map{|f| File.join(src_dir, f)}
      dest_dir = ContributionsHelper.contribution_dir(contribution)
      FileUtils.mkdir_p(dest_dir)
      FileUtils.cp(files, dest_dir)
    end


    context "download all files" do
      it "downloads all files as zip when contribution contains file(s)" do

        pattern = "*"
        zip_path = ContributionsHelper.export_as_zip(contribution, pattern)
        expected_zip_path = File.join(APP_CONFIG['download_tmp_dir'], "contrib_export_#{contribution.id}_")
        expect(zip_path).to start_with "#{expected_zip_path}"

      end
    end
  end

  describe "test all_related_files" do
    let!(:doc_1) {FactoryGirl.create(:document, item: item, file_name: "Rodney.wav")}
    let!(:doc_2) {FactoryGirl.create(:document, item: item, file_name: "Isaac.wav")}
    let!(:doc_3) {FactoryGirl.create(:document, item: item, file_name: "Phoebe.wav")}

    let!(:contrib_doc_1) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Rodney.ps")}
    let!(:contrib_doc_2) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Isaac.txt")}
    let!(:contrib_doc_3) {FactoryGirl.create(:document, item: item, file_name: "#{item.get_name}-Phoebe.txt")}

    let!(:contrib_mapping_1) {FactoryGirl.create(:contribution_mapping, contribution: contribution, document: contrib_doc_1)}
    let!(:contrib_mapping_2) {FactoryGirl.create(:contribution_mapping, contribution: contribution, document: contrib_doc_2)}
    let!(:contrib_mapping_3) {FactoryGirl.create(:contribution_mapping, contribution: contribution, document: contrib_doc_3)}

    before do
      src_dir = "#{Rails.root}/test/samples/contributions/contrib_doc"
      files = [doc_1.file_name, doc_2.file_name, doc_3.file_name].map{|f| File.join(src_dir, f)}
      dest_dir = ContributionsHelper.contribution_dir(contribution)
      FileUtils.mkdir_p(ContributionsHelper.contribution_dir(contribution))
      FileUtils.cp(files, dest_dir)
    end

    context "wildcard is '*'" do
      it "returns all files" do
        files = ContributionsHelper.all_related_files(contribution, '*')

        expected_files = Document.find_all_by_item_id(item.id).map{|f| f.file_path}

        expected_files.each do |f|
          expect(files.include? (f)).to be_true
        end
      end
    end

    context "wildcard is nil" do
      it "returns all files" do
        files = ContributionsHelper.all_related_files(contribution)

        expected_files = Document.find_all_by_item_id(item.id).map{|f| f.file_path}

        expected_files.each do |f|
          expect(files.include? (f)).to be_true
        end
      end
    end

    context "wildcard is single file type" do
      it "returns all files" do
        files = ContributionsHelper.all_related_files(contribution, '*.ps')

        expected_files = Document.find_all_by_item_id(item.id).select{|f| f.file_path.ends_with? ('.ps')}

        expected_files.each do |f|
          expect(files.include? (f.file_path)).to be_true
        end
      end
    end

    context "wildcard is multi file type" do
      it "returns all files" do
        files = ContributionsHelper.all_related_files(contribution, '*.ps, *.txt')

        expected_files = Document.find_all_by_item_id(item.id).select{|f| f.file_path.ends_with?('.ps') || f.file_path.ends_with?('.txt')}

        expected_files.each do |f|
          expect(files.include? (f.file_path)).to be_true
        end
      end
    end

    context "wildcard is particular pattern" do
      it "returns all files" do
        files = ContributionsHelper.all_related_files(contribution, 'Rodney')

        expected_files = Document.find_all_by_item_id(item.id).select{|f| f.file_path.include?('Rodney')}

        expected_files.each do |f|
          expect(files.include? (f.file_path)).to be_true
        end
      end
    end


  end
end


require 'zip/zip'

class ZipBuilder

  # Build zip from files.
  #
  # @param zip_path destination zip file
  # @param file_details files to be zipped
  # @return [Object]
  def self.build_simple_zip_from_files(zip_path, file_details)

    file_size = 0

    Zip::ZipFile.open(zip_path, Zip::ZipFile::CREATE) do |zipfile|
      file_details.each do |file|
        file_path = file
        basename = File.basename(file_path)

        # Takes two arguments:
        # - The basename of the file as it will appear in the archive
        # - The original file, including the path to find it

        file_size += File.size(file_path)

        zipfile.add(basename, file_path)
      end
    end

    logger.debug "build_simple_zip_from_files: #{zip_path} file size: #{file_size.to_s}, zip size: (#{File.new(zip_path).size}) done"
  end

  def self.build_zip(zip_file, file_paths)
    Zip::ZipOutputStream.open(zip_file.path) do |zos|
      file_paths.each do |path|
        if File.directory?(path)
          process_directory(zos, nil, path)
        else
          add_single_file(zos, nil, path)
        end
      end
    end
  end

  private

  def self.process_directory(zos, rootPath, directoryPath)
    dir_name = File.basename(directoryPath)
    all_files = Dir.foreach(directoryPath).reject {|f| f.starts_with?(".")}
    all_files.each do |file|
      filePath = "#{directoryPath}/#{file}"
      newRootPath = (rootPath.nil?) ? dir_name : "#{rootPath}/#{dir_name}"
      if File.directory?(filePath)
        process_directory(zos, newRootPath, filePath)
      else
        add_single_file(zos, newRootPath, filePath)
      end
    end
  end

  def self.add_single_file(zos, rootPath, path)

    # Single file processing
    entry = (rootPath.nil?) ? File.basename(path) : "#{rootPath}/#{File.basename(path)}"

    zos.put_next_entry(entry)
    begin
      file = File.open(path, 'rb')
      write_to_zip(zos, file)
    ensure
      file.close if !file.nil?
    end
  end

  def self.write_to_zip(zos, file)
    chunk_size = 1024 * 1024
    each_chunk(file, chunk_size) do |chunk|
      zos << chunk
    end
  end

  def self.each_chunk(file, chunk_size = 1024)
    yield file.read(chunk_size) until file.eof?
  end
end
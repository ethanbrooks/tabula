require 'open3'

require_relative '../detect_rulings.rb'


class AnalyzePDFJob
  # args: (:file_id, :file, :output_dir, :sm_thumbnail_job, :lg_thumbnail_job)
  # Runs the jruby PDF analyzer on the uploaded file.
  include Resque::Plugins::Status
  Resque::Plugins::Status::Hash.expire_in = (30 * 60) # 30min
  @queue = :pdftohtml

  def perform
    file_id = options['file_id']
    file = options['file']
    output_dir = options['output_dir']
    # not a good idea to spawn these from within this job (in case we are
    # on an env with just one workier -- if we spawn from here, the thumbnail
    # jobs would wait for this one). so spawn from main first and have *that*
    # pass the IDs to here.
    sm_thumbnail_job = options['sm_thumbnail_job']
    lg_thumbnail_job = options['lg_thumbnail_job']
    upload_id = self.uuid

    # return some status to browser
    at(0, 100, "analyzing PDF text...",
      'file_id' => file_id,
      'upload_id' => upload_id,
      'thumbnails_complete' => true
    )

    # open a subprocess and catch input/output/stderr (and a reference
    # to our thread that watches it). this opens asynchronously
    # so we can continually handle the output stream.
    _stdin, _stdout, _stderr, thr = Open3.popen3(
        {"CLASSPATH" => "lib/jars/pdfbox-app-1.8.0.jar"},
        "#{Settings::JRUBY_PATH} --1.9 --server lib/jruby_dump_characters.rb #{file} #{output_dir}"
    )

    # handle stderr (which is where we are "printing" the page number
    # status -- see near bottom of libs/jruby_dump_characters.rb)
    _stderr.each { |line|
      progress, total = line.split('///', 2)

      if progress.nil? || total.nil?
        # TODO: some PDF files will result in warnings generated by
        #       pdfbox. right now we'll just skip them (and pass them
        #       on to the user).
        STDERR.puts(line)
        next
      end

      progress = (progress.strip).to_i
      total = (total.strip).to_i
      if total === 0
        total = 1
      end

      #puts "#{progress} of #{total} (#{converted_progress}%)"
      at(progress, total+2, "processing page #{progress} of #{total}...",
         'file_id' => file_id,
         'upload_id' => upload_id
         )
    }
    _stdin.close
    _stdout.close
    _stderr.close

    # catch exit code of jruby/pdfbox process
    # TODO: if fail, should probably do something useful with stderr
    # TODO: if fail, should clean up upload directory
    exit_status = thr.value.exitstatus
    if exit_status != 0
        failed(
           'file_id' => file_id,
           'upload_id' => upload_id
        )
        return nil
    else
      # If thumbnail jobs haven't finished, wait up for them
      while (!Resque::Plugins::Status::Hash.get(sm_thumbnail_job).completed? || !Resque::Plugins::Status::Hash.get(lg_thumbnail_job).completed?) do
        at(99, 100, "generating thumbnails...",
          'file_id' => file_id,
          'upload_id' => upload_id
        )
        sleep 0.25
      end

      at(100, 100, "complete",
         'file_id' => file_id,
         'upload_id' => upload_id,
         'thumbnails_complete' => true
         )

      return nil
    end
  end
end

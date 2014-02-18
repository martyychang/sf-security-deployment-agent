# The Convenience module defines methods for conveniently doing stuff in
# the context of this script, such as logging debug messages
module Convenience
    def debug comments, category = "DEBUG"
        puts "#{Time.now}|#{category}|#{comments}"
        
        #unless log_path.nil?
        #    File.open(log_path, "a+b") do |f|
        #        f.write comments + "\r\n"
        #    end
        #end
    end
    
    def warning comments
        debug comments, "WARNING"
    end
    
    def error comments
        debug comments, "ERROR"
    end
end
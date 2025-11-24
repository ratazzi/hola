# File::Stat wrapper class to make Hash behave like File::Stat object
class File
  class Stat
    def initialize(hash)
      @hash = hash
    end

    def mtime
      Time.at(@hash['mtime'])
    end

    def atime
      Time.at(@hash['atime'])
    end

    def size
      @hash['size']
    end

    def mode
      @hash['mode']
    end
  end
end

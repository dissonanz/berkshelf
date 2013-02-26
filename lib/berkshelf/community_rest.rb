require 'open-uri'

module Berkshelf
  # @author Jamie Winsor <reset@riotgames.com>
  class CommunityREST < Faraday::Connection
    class << self
      # @param [String] target
      #   file path to the tar.gz archive on disk
      # @param [String] destination
      #   file path to extract the contents of the target to
      #
      # @return [String]
      def unpack(target, destination = Dir.mktmpdir)
        Archive::Tar::Minitar.unpack(Zlib::GzipReader.new(File.open(target, 'rb')), destination)
        destination
      end

      # @param [String] version
      #
      # @return [String]
      def uri_escape_version(version)
        version.gsub('.', '_')
      end

      # @param [String] uri
      #
      # @return [String]
      def version_from_uri(uri)
        File.basename(uri).gsub('_', '.')
      end
    end

    V1_API = 'http://cookbooks.opscode.com/api/v1/cookbooks'.freeze

    attr_reader :api_uri

    def initialize(uri = V1_API)
      @api_uri = Addressable::URI.parse(uri)

      builder = Faraday::Builder.new do |b|
        b.response :json
        b.adapter :net_http
      end

      super(api_uri, builder: builder)
    end

    # @param [String] name
    # @param [String] version
    #
    # @return [String]
    def download(name, version)
      archive = stream(find(name, version)[:file])
      self.class.unpack(archive.path)
    ensure
      archive.unlink unless archive.nil?
    end

    def find(name, version)
      response = get("#{name}/versions/#{self.class.uri_escape_version(version)}")

      case response.status
      when (200..299)
        response.body
      when 404
        raise CookbookNotFound, "Cookbook '#{name}' not found at site: '#{api_uri}'"
      else
        raise CommunitySiteError, "Error finding cookbook '#{name}' (#{version}) at site: '#{api_uri}'"
      end
    end

    # Returns the latest version of the cookbook and it's download link.
    #
    # @return [String]
    def latest_version(name)
      response = get(name)

      case response.status
      when (200..299)
        self.class.version_from_uri response.body['latest_version']
      when 404
        raise CookbookNotFound, "Cookbook '#{name}' not found at site: '#{api_uri}'"
      else
        raise CommunitySiteError, "Error retrieving latest version of cookbook '#{name}' at site: '#{api_uri}'"
      end
    end

    # @param [String] name
    #
    # @return [Array]
    def versions(name)
      response = get(name)

      case response.status
      when (200..299)
        response.body['versions'].collect do |version_uri|
          self.class.version_from_uri(version_uri)
        end
      when 404
        raise CookbookNotFound, "Cookbook '#{name}' not found at site: '#{api_uri}'"
      else
        raise CommunitySiteError, "Error retrieving versions of cookbook '#{name}' at site: '#{api_uri}'"
      end
    end

    # @param [String] name
    # @param [String, Solve::Constraint] constraint
    #
    # @return [String]
    def satisfy(name, constraint)
      Solve::Solver.satisfy_best(constraint, versions(name)).to_s
    rescue Solve::Errors::NoSolutionError
      nil
    end

    # Stream the response body of a remote URL to a file on the local file system
    #
    # @param [String] target
    #   a URL to stream the response body from
    #
    # @return [Tempfile]
    def stream(target)
      local = Tempfile.new('community-rest-stream')
      local.binmode

      open(target, 'rb', headers) do |remote|
        local.write(remote.read)
      end
      
      local
    ensure
      local.close(false) unless local.nil?
    end
  end
end
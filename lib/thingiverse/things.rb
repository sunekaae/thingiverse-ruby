module Thingiverse
  class Things
    include ActiveModel::Validations
    validates_presence_of :name

    attr_accessor :id, :name, :thumbnail, :url, :public_url, :creator, :added, :modified, :is_published, :is_wip
    attr_accessor :ratings_enabled, :like_count, :description, :instructions, :license
    attr_accessor :files_url, :images_url, :likes_url, :ancestors_url, :derivatives_url, :tags_url, :categories_url
    attr_accessor :category, :ancestors, :tags

    def initialize(params={})
      params.each do |name, value|
        send("#{name}=", value)
      end
    end

    def attributes
      {
        :id => id.to_s,
        :name => name.to_s,
        :thumbnail => thumbnail.to_s,
        :url => url.to_s,
        :public_url => public_url.to_s,
        :creator => creator.to_s,
        :added => added.to_s,
        :modified => modified.to_s,
        :is_published => is_published != true ? false : true,
        :is_wip => is_wip != true ? false : true,
        :ratings_enabled => ratings_enabled != true ? false : true,
        :like_count => like_count.to_s,
        :description => description.to_s,
        :instructions => instructions.to_s,
        :license => license.to_s,
        :files_url => files_url.to_s,
        :images_url => images_url.to_s,
        :likes_url => likes_url.to_s,
        :ancestors_url => ancestors_url.to_s,
        :derivatives_url => derivatives_url.to_s,
        :tags_url => tags_url.to_s,
        :categories_url => categories_url.to_s,
        :category => category.to_s,
        :ancestors => ancestors || [],
        :tags => tags || []
      }
    end

    def user
      response = Thingiverse::Connection.get("/users/#{creator['name']}")
      raise "#{response.code}: #{JSON.parse(response.body)['error']}" unless response.success?
      Thingiverse::Users.new response.parsed_response
    end

    def files(query = {})
      Thingiverse::Pagination.new(Thingiverse::Connection.get(@files_url, :query => query), Thingiverse::Files)
    end

    def images(query = {})
      Thingiverse::Pagination.new(Thingiverse::Connection.get(@images_url, :query => query), Thingiverse::Images)
    end

    def categories(query = {})
      Thingiverse::Pagination.new(Thingiverse::Connection.get(@categories_url, :query => query), Thingiverse::Categories)
    end

    def parents(query = {})
      Thingiverse::Pagination.new(Thingiverse::Connection.get(@ancestors_url, :query => query), Thingiverse::Things)
    end

    # TODO: this is a dumb name, come up with a better way to set/retrieve
    def tag_records
      response = Thingiverse::Connection.get(tags_url)
      raise "#{response.code}: #{JSON.parse(response.body)['error']}" unless response.success?
      response.parsed_response.collect do |attrs|
        Thingiverse::Tags.new attrs
      end
    end

    def save
      if id.to_s == ""
        thing = Thingiverse::Things.create(attributes)
      else
        raise "Invalid Parameters" unless self.valid?

        response = Thingiverse::Connection.patch("/things/#{id}", :body => attributes.to_json)
        raise "#{response.code}: #{JSON.parse(response.body)['error']}" unless response.success?

        thing = Thingiverse::Things.new(response.parsed_response)
      end

      thing.attributes.each do |name, value|
        send("#{name}=", value)
      end
    end
    
    def upload(file)
      upload_from_file_or_string('file', file, nil, nil)
    end

    def upload_from_string(file_content, file_name)
      upload_from_file_or_string('string', nil, file_content, file_name)
    end

    # bit hacky.
    # file_or_string should be 'file' or 'string'
    # if 'file' then pass along a file object in 'file'
    # if 'string' then pass along the content to upload in 'file_content' and the intended file name in 'file_name'
    # leave unused vars as nil
    def upload_from_file_or_string(file_or_string, file, file_content, file_name)
      raise "file_or_string option not recognized" if (!file_or_string == 'file' && !file_or_string == 'string')
      
      if file_or_string == 'file' then
        file_name = file_name = File.basename(file.path)
      end
      
      response = Thingiverse::Connection.post("/things/#{id}/files", :body => {:filename => file_name}.to_json)
      raise "#{response.code}: #{JSON.parse(response.body)['error']} #{response.headers['x-error']}" unless response.success?

      parsed_response = JSON.parse(response.body)
      action = parsed_response["action"]
      query = parsed_response["fields"]
      if file_or_string == 'file' then
        query["file"] = file
      end

      # stupid S3 requires params to be in a certain order... so can't use HTTParty :(
      # prepare post data
      post_data = []
      # TODO: is query['bucket'] needed here?
      post_data << Curl::PostField.content('key',                     query['key'])
      post_data << Curl::PostField.content('AWSAccessKeyId',          query['AWSAccessKeyId'])
      post_data << Curl::PostField.content('acl',                     query['acl'])
      post_data << Curl::PostField.content('success_action_redirect', query['success_action_redirect'])
      post_data << Curl::PostField.content('policy',                  query['policy'])
      post_data << Curl::PostField.content('signature',               query['signature'])
      post_data << Curl::PostField.content('Content-Type',            query['Content-Type'])
      post_data << Curl::PostField.content('Content-Disposition',     query['Content-Disposition'])

      if file_or_string == 'file' then
        post_data << Curl::PostField.file('file', file.path)
      else
        post_data << Curl::PostField.file('file', file_name) { file_content }
      end

      # post
      c = Curl::Easy.new(action) do |curl|
        # curl.verbose = true
        # can't follow redirect to finalize here because need to pass access_token for auth
        curl.follow_location = false
      end
      c.multipart_form_post = true
      c.http_post(post_data)

      if c.response_code == 303
        # finalize it
        response = Thingiverse::Connection.post(query['success_action_redirect'])
        raise "#{response.code}: #{JSON.parse(response.body)['error']} #{response.headers['x-error']}" unless response.success?
        Thingiverse::Files.new(response.parsed_response)
      else
        raise "#{c.response_code}: #{c.body_str}"
      end
    end


    def publish
      if id.to_s == ""
        raise "Cannot publish until thing is saved"
      else
        response = Thingiverse::Connection.post("/things/#{id}/publish")
        raise "#{response.code}: #{JSON.parse(response.body)['error']}" unless response.success?

        thing = Thingiverse::Things.new(response.parsed_response)
      end

      thing.attributes.each do |name, value|
        send("#{name}=", value)
      end
    end

    def self.find(thing_id)
      response = Thingiverse::Connection.get("/things/#{thing_id}")
      raise "#{response.code}: #{JSON.parse(response.body)['error']} #{response.headers['x-error']}" unless response.success?
      self.new response.parsed_response
    end

    def self.newest(query = {})
      Thingiverse::Pagination.new(Thingiverse::Connection.get('/newest', :query => query), Thingiverse::Things)
    end

    def self.create(params)
      thing = self.new(params)
      raise "Invalid Parameters" unless thing.valid?

      response = Thingiverse::Connection.post('/things', :body => thing.attributes.to_json)
      raise "#{response.code}: #{JSON.parse(response.body)['error']} #{response.headers['x-error']}" unless response.success?

      self.new(response.parsed_response)
    end

  end
end

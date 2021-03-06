require 'mongo'

# TODO !! Need to deal with auth
# BOZO !! Deal with indexes here ?
module Rackamole
  module Store
    # Mongo adapter. Stores mole info to a mongo database.
    class MongoDb
      
      attr_reader :host, :port, :db_name, :database, :logs, :features, :users #:nodoc:
            
      # Initializes the mongo db store. MongoDb can be used as a persitent store for
      # mole information. This is a preferred store for the mole as it will allow you
      # to gather up reports based on application usage, perf or faults...
      #
      # Setup rackamole to use the mongodb store as follows:
      #
      #   config.middleware.use Rack::Mole, { 
      #     :store => Rackamole::Store::MongoDb.new( 
      #       :db_name  => 'mole_blee_development_mdb',
      #       :username => 'fernand',
      #       :password => 'letmein',
      #      ) 
      #   }
      #
      # === NOTE 
      #
      # To use in conjunction with Wackamole your db_name must follow 
      # the convention "mole_[app_name]_[environment]_mdb".
      #
      # === Options
      #
      # :host     :: The name of the host running the mongo server. Default: localhost
      # :port     :: The port for the mongo server instance. Default: 27017
      # :db_name  :: The name of the mole databaase. Default: mole_mdb
      # :username :: username if the mongo db has auth setup. optional
      # :password :: password if the mongo db has auth required. optional
      #
      def initialize( options={} )
        opts = default_options.merge( options )
        validate_options( opts )
        init_mongo( opts )
      end
            
      def to_yaml( opts={} )
        YAML::quick_emit( object_id, opts ) do |out|
          out.map( taguri, to_yaml_style ) do |map|
            map.add( :host    , host )
            map.add( :port    , port )
            map.add( :db_name , db_name )
          end
        end
      end
      
      # Dump mole info to a mongo database. There are actually 2 collections
      # for mole information. Namely features and logs. The features collection hold
      # application and feature information and is referenced in the mole log. The logs
      # collections holds all information that was gathered during the request
      # such as user, params, session, request time, etc...
      def mole( arguments )
        return if arguments.empty?       
        
        unless @connection
          init_mongo( :host => host, :port => port, :db_name => db_name )
        end
        
        # get a dup of the args since will mock with the original
        args = arguments.clone

        # dump request info to mongo
        save_log( save_user( args ), save_feature( args ), args )
      rescue => mole_boom
        $stderr.puts "MOLE STORE CRAPPED OUT -- #{mole_boom}"
        $stderr.puts mole_boom.backtrace.join( "\n   " )        
      end

      # =======================================================================
      private
        
        # Clear out mole database content ( Careful there - testing only! )
        def reset!
          logs.remove
          features.remove
          users.remove
        end

        def init_mongo( opts )
          @host       = opts[:host]
          @port       = opts[:port]
          @db_name    = opts[:db_name]
          
          @connection = Mongo::Connection.new( @host, @port, :logger => opts[:logger] )          
          @database   = @connection.db( @db_name )
          
          if opts[:username] and opts[:password]
            authenticated = @database.authenticate( opts[:username], opts[:password] )
            raise "Authentication failed for database #{@db_name}. Please check your credentials and try again" unless authenticated
          end
          
          @features = database.collection( 'features' )
          @logs     = database.collection( 'logs' )
          @users    = database.collection( 'users' )
        end

        # Validates option hash.
        def validate_options( opts )     
          %w[host port db_name].each do |option|
            unless opts[option.to_sym]
              raise "[MOle] Mongo store configuration error -- You must specify a value for option `:#{option}" 
            end
          end
          # check for auth
          if opts[:username]
            %w(username password).each do |option|
              unless opts[option.to_sym]
                raise "[MOle] Mongo store configuration error -- You must specify a value for auth option `:#{option}" 
              end
            end
          end
        end
                
        # Set up mongo default options ie localhost host, default mongo port and
        # the database being mole_mdb      
        def default_options
          {
             :host => 'localhost',
             :port => Mongo::Connection::DEFAULT_PORT
          }
        end
        
        # Find or create a moled user...
        # BOZO !! What to do if user name changed ?
        def save_user( args )
          user_id   = args.delete( :user_id ) if args.has_key?( :user_id )
          user_name = args.delete( :user_name ) if args.has_key?( :user_name )
        
          row = {}
          if user_id and user_name
            row = { min_field( :user_id ) => user_id, min_field( :user_name ) => user_name }
          else
            row = { min_field( :user_name ) => user_name }
          end
                    
          user = users.find_one( row, :fields => ['_id'] )
          return user['_id'] if user

          now = args[:created_at]
          row[min_field(:date_id)] = "%4d%02d%02d" % [now.year, now.month, now.day]
                    
          users.save( row )
        end
        
        # Find or create a mole feature...
        def save_feature( args )
          app_name    = args.delete( :app_name )
          route_info  = args.delete( :route_info )
          environment = args.delete( :environment )
        
          row = { min_field(:app_name) => app_name, min_field(:env) => environment.to_s }
          if route_info
            row[min_field(:controller)] = route_info[:controller]
            row[min_field(:action)]     = route_info[:action]
          else
            row[min_field(:context)] = args.delete( :path )
          end
          
          feature = features.find_one( row, :fields => ['_id'] )
          return feature['_id'] if feature

          now = args[:created_at]
          row[min_field(:date_id)] = "%4d%02d%02d" %[now.year, now.month, now.day]
                    
          features.save( row )
        end
                                    
        # Insert a new feature in the db
        # NOTE : Using min key to reduce storage needs. I know not that great for higher level api's :-(
        # also saving date and time as ints. same deal...
        def save_log( user_id, feature_id, args )
          now = args.delete( :created_at )
          row = {
            min_field( :type )       => args[:type],
            min_field( :feature_id ) => feature_id,
            min_field( :user_id )    => user_id,
            min_field( :date_id )    => "%4d%02d%02d" %[now.year, now.month, now.day],
            min_field( :time_id )    => "%02d%02d%02d" %[now.hour, now.min, now.sec]
          }
          
          args.each do |k,v|
            row[min_field(k)] = check_hash( v ) if v
          end
          logs.save( row )
        end
        
        # Check for invalid key format - ie something that will choke mongo
        # case a.b.c => a_b_c
        def ensure_valid_key( key )
          key.to_s.index( /\./ ) ? key.to_s.gsub( /\./, '_' ) : key
        end
        
        # Check 
        def check_hash( value )
          return value unless value.is_a?( Hash )
          value.keys.inject({}){ |h,k| h[ensure_valid_key(k)] = value[k];h }
        end
        
        # For storage reason minify the json to save space...
        def min_field( field )
          Rackamole::Store::MongoDb.field_map[field] || field
        end
            
        # Normalize all accessors to 3 chars. 
        def self.field_map
          @field_map ||= {
            :env          => :env,
            :app_name     => :app,
            :context      => :ctx,
            :controller   => :ctl,
            :action       => :act,
            :type         => :typ,
            :feature_id   => :fid,
            :date_id      => :did,
            :time_id      => :tid,
            :user_id      => :uid,
            :user_name    => :una,
            :browser      => :bro,
            :machine      => :mac,
            :host         => :hos,
            :software     => :sof,
            :request_time => :rti,
            :performance  => :per,
            :method       => :met,
            :path         => :pat,
            :session      => :ses,
            :params       => :par,
            :ruby_version => :ver,
            :fault        => :msg,
            :stack        => :sta,
            :created_at   => :cro,
            :status       => :sts,
            :headers      => :hdr,
            :body         => :bod
          }
        end      
    end
  end
end
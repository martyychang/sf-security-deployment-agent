API_VERSION = 29.0
EXPECTED_NUM_ARGS = 2

# Check for the expected number of arguments

abort "wrong number of arguments (#{ARGV.size} for #{EXPECTED_NUM_ARGS})" if ARGV.size != EXPECTED_NUM_ARGS

# Read the arguments

partner_wsdl_path = ARGV.shift  # e.g., "partner-29.0-sandbox.wsdl"
metadata_wsdl_path = ARGV.shift  # e.g., "metadata-29.0-sandbox.wsdl"

# Validate file path parameters

file_paths = [partner_wsdl_path, metadata_wsdl_path]

file_paths.each do |path|
    abort "File not found: #{path}" if !File.exists? path
end

# Require libraries

require "base64"
require "savon"

# Set some basic script parameters

script_name = $0
start_time = Time.now
output_zip_path = "#{script_name.split(".rb").first}-#{start_time.to_i}.zip"

# Initialize the two API clients

partner_client = Savon.client wsdl: partner_wsdl_path, ssl_verify_mode: :none
metadata_client = Savon.client wsdl: metadata_wsdl_path, ssl_verify_mode: :none

# Get the username, password and security token

puts "Username:"
username = gets.chomp  # e.g., "martyc@hanover.com.sandbox"

puts "Password (WAITASEC, whatever you type is going to show on the screen):"
password = gets.chomp  # e.g., "Ruby1sAwesome!"

puts "Security Token:"
token = gets.chomp  # e.g., ""

# Log into Salesforce!

login_message = { username: username, password: password + token }
soap_response = partner_client.call :login, message: login_message
soap_response_hash = soap_response.hash
login_result = soap_response_hash[:envelope][:body][:login_response][:result]

# Retrieve the two key pieces of information needed for the Metadata API:
# the metadata server URL and the session ID

metadata_server_url = login_result[:metadata_server_url]
session_id = login_result[:session_id]

metadata_client.globals.endpoint metadata_server_url

# Let's just describe the metadata to see what's available
# This will also let us know that the client is functioning correctly

describe_metadata_header = { "tns:SessionHeader" => { "tns:sessionId" => session_id } }
describe_metadata_message = { as_of_version: API_VERSION }

soap_response = metadata_client.call :describe_metadata, soap_header: describe_metadata_header, message: describe_metadata_message
soap_response_hash = soap_response.hash

describe_metadata_result = soap_response_hash[:envelope][:body][:describe_metadata_response][:result]

# Let's see what we can find out about permission sets
# The way the metadata objects are stored in an array, and each array element
# is a hash that contains attributes about the available metadata object.
#  - :suffix is (guess) the file suffix of a retrieved file
#  - :directory_name is (guess) the directory in which the metadata file will
#    be stored upon retrieval
#  - :xml_name is what we would normally put into the name element when
#    manually building a package.xml file for migration
#  - :in_folder is unknown; looks like a boolean true/false
#  - :meta_file is unknown; looks like a boolean true/false
#  - :child_xml_names appears to be an optional element, which could be either
#    a single string or an array of strings representing the XML names of
#    child metadata objects

metadata_objects = describe_metadata_result[:metadata_objects]

# Let's compile the metadata objects into a hash that's easier to access
# by known metadata object XML names

metadata_objects = {}  # Yes, we're repurposing this variable
describe_metadata_result[:metadata_objects].each do |object|
    metadata_objects[object[:xml_name]] = object
end

# Let's start building out a more robust "give me everything I want and more"
# mode of retrieving metadata, simply by specifying a list of XML names

wanted_object_names = [
    "ApexClass",
    "ApexPage",
    "CustomApplication",
    "CustomLabels",
    "CustomObject",
    "CustomTab", 
    "Dashboard",
    "Group",
    "Layout", 
    "PermissionSet", 
    "Profile",
    "Report",
    "ReportType"
]
wanted_child_object_names = []  # This may be filled as a result of the above

# To be sure that we're not too greedy, let's check that all of our wanted
# object names are actually ones recognized by the Metadata API for the org
# we're connected to
#
# While we're at it, if we detect that any objects in the list has child
# associated child objects, let's make sure to add those to the list as well

wanted_object_names.each do |object_name|
    abort "Unrecognized metadata object name: #{object_name}" unless metadata_objects.keys.include? object_name
    
    # Never mind...
    # Child objects are simply included in the base object as part of the 
    # CustomObject XML document
    
    #object = metadata_objects[object_name]
    #if object.has_key? :child_xml_names
    #    child_xml_names = object[:child_xml_names]
    #    if child_xml_names.respond_to? :each
    #        child_xml_names.each do |child_xml_name|
    #            wanted_child_object_names.push child_xml_name
    #        end
    #    else
    #        wanted_child_object_names.push child_xml_names
    #    end
    #end
end

wanted_object_names += wanted_child_object_names
wanted_object_names = wanted_object_names.uniq.sort

# Now that we know what we want, we need to iterate through all of them
# to build out the array of types elements we need to include in the
# final retrieve request

wanted_object_types = []
wanted_object_names.each do |object_name|
    
    object = metadata_objects[object_name]
    
    # Let's first see what object instances are out there to be retrieved!
    # We'll use a the listMetadata() operation to accomplish this

    list_metadata_header = { "tns:SessionHeader" => { "tns:sessionId" => session_id } }
    
    # We need to handle situations where the metadata object has folders
    # Sf says in this case we need to query for the folder by using
    # listMetadata() and appending the word "Folder" to the metadata object
    # name
    
    folder_queries = []  # All folder-specific queries to be executed
    
    if object[:in_folder]
        list_folder_metadata_header = list_metadata_header.clone
        list_folder_metadata_message = {
            queries: { type: "#{object_name}Folder" },
            as_of_version: API_VERSION
        }
        
        soap_response = metadata_client.call :list_metadata, soap_header: list_folder_metadata_header, message: list_folder_metadata_message
        soap_response_hash = soap_response.hash
        
        list_folder_metadata_response = soap_response_hash[:envelope][:body][:list_metadata_response]
        
        unless list_folder_metadata_response.nil?
            list_folder_metadata_result = list_folder_metadata_response[:result]
            
            # The result is an array of hashes, each of which contains info
            # on that specific folder. In our case, the useful name is the
            # :full_name value
            #
            # We need to add the folder full name to the metadata object's
            # listMetadata() request as 
            
            list_folder_metadata_result = [list_folder_metadata_result] if list_folder_metadata_result.respond_to? :has_key?
            
            list_folder_metadata_result.each do |result|
                folder_query = {
                    folder: "#{result[:full_name]}",
                    type: object_name
                }
                
                folder_queries.push folder_query
            end
        end # unless list_folder_metadata_response.nil?
    end
    
    # We need to make the list of queries into something iterable
    # so that we don't have to write different code for folder queries
    
    queries = object[:in_folder] ? folder_queries : [{ type: object_name }]
    
    # Let's get all of our members (a.k.a. components)!
    
    begin
        members = []  # To contain all members of this metadata object
        members = ["Dashboard", "Report"] if object_name == "CustomObject"
        
        queries.each do |query|
            list_metadata_message = {
                queries: query,
                as_of_version: API_VERSION
            }
            
            soap_response = metadata_client.call :list_metadata, soap_header: list_metadata_header, message: list_metadata_message
            soap_response_hash = soap_response.hash

            list_metadata_response = soap_response_hash[:envelope][:body][:list_metadata_response]
            
            # The SOAP response could include an empty response element
            # if there are actually no items in a particular folder
            # or no matching items retrieved in a particular request
            
            unless list_metadata_response.nil?
                list_metadata_result = list_metadata_response[:result]
                
                # We know the object name, which will go inside the name element
                # We now also know the full names of the individual object instances,
                # which will each go inside a members element
                
                list_metadata_result = [list_metadata_result] if list_metadata_result.respond_to? :has_key?

                list_metadata_result.each do |item|
                    members.push item[:full_name]
                end
            end
        end
        
        # Construct the types hash and push it into the master list of types
        
        wanted_object_types.push({ members: members, name: object_name })
    rescue Savon::SOAPFault => fault
        puts fault
    end
end

# Well, this was fun. We presumably now have our master list of types
# to include in our retrieve() operation

# Let's move on and actually use this information to bulid a retrieve request
# and pull all of the metadata back on this stuff!

retrieve_header = { "tns:SessionHeader" => { "tns:sessionId" => session_id } }
retrieve_message = {
    retrieve_request: {
        api_version: API_VERSION,
        #package_names: We should dynamically build this... later
        single_package: true,
        #specific_files: permission_set_files,
        unpackaged: {
            types: wanted_object_types,
            version: API_VERSION
        }
    }
}

soap_response = metadata_client.call :retrieve, soap_header: retrieve_header, message: retrieve_message
soap_response_hash = soap_response.hash

retrieve_result = soap_response_hash[:envelope][:body][:retrieve_response][:result]

# We expect the result to be queued, so let's check to make sure
# that it indeed has been queued

abort "Unexpected retrieve() state: #{retrieve_result[:state]}" if retrieve_result[:state] != "Queued"

# Let's keep checking on the request until it comes back ready with our
# zip file! We probably need to handle situations where it errors out...
# but whatever for now!

begin
    sleep 6  # Wait 6 seconds, becuase we're good cloud citizens
    
    check_retrieve_status_header = {
        "tns:SessionHeader" => { "tns:sessionId" => session_id }
    }
    check_retrieve_status_message = {
        async_process_id: retrieve_result[:id]
    }
    
    soap_response = metadata_client.call :check_retrieve_status, soap_header: check_retrieve_status_header, message: check_retrieve_status_message
    soap_response_hash = soap_response.hash
    
    check_retrieve_status_result = soap_response_hash[:envelope][:body][:check_retrieve_status_response][:result]
    has_zip_file = check_retrieve_status_result.has_key? :zip_file
rescue Savon::SOAPFault => fault
    puts fault
    has_zip_file = false
end until has_zip_file

# Let's pump out the .zip file!

File.open(output_zip_path, "wb") do |f|
    f.write Base64.decode64(check_retrieve_status_result[:zip_file])
end
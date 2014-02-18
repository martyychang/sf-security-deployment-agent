# The goal of this script is to take a full-featured package retrieved from
# another org and pare it down so that it matches what's available in
# the destination org. The reason is that if things configured don't exist,
# we'll end up in a world of hurt in terms of deployment errors.
#
# Not only do we need to prune all of this, it would be very useful to produce
# a log of permissions that were stripped out of the package. This way,
# if there are layout assignments to record types that don't exist, we can
# figure out how to handle them.
#
# Also, for debugging purposes, we should know which implicit permissions were
# explicitly added. For example, disabled user permissions must be added to
# make them stick in the destination org.
#
# I think we can cheat with the log file and just create it as a CSV. I'd like
# to at some point create it as an XLSX file, now that I've discovered all
# an XLSX file is a .zip with a bunch of XML files inside.
#
# The CSV file can have the following column headers:
#   - Profile name
#   - Permission element tag name
#   - Component name
#   - "Added" or "Removed"

# Okay... now down to business.

APEX_CLASS_XML_NAME = "ApexClass"
APEX_PAGE_XML_NAME = "ApexPage"
CUSTOM_APPLICATION_XML_NAME = "CustomApplication"
CUSTOM_OBJECT_XML_NAME = "CustomObject"
CUSTOM_TAB_XML_NAME = "CustomTab"
DEFAULT_KNOWNS_CSV_PATH = "knowns.csv"
FIELDS_FIELD_NAME = "fields"
LAYOUT_XML_NAME = "Layout"
MIN_EXPECTED_NUM_ARGS = 2
OBJECT_FILE_EXTENSION = ".object"
PACKAGE_XML_FILENAME = "package.xml"
PROFILE_FILE_EXTENSION = ".profile"
RECORD_TYPES_FIELD_NAME = "recordTypes"
USER_PERMISSIONS_FIELD_NAME = "userPermissions"

# Check for expected number of arguments

abort "wrong number of arguments (at least #{MIN_EXPECTED_NUM_ARGS})" if ARGV.size < MIN_EXPECTED_NUM_ARGS

# Store the arguments

source_zip_path = ARGV.shift
destination_zip_path = ARGV.shift
knowns_csv_path = ARGV.shift

# Set script parameters

start_time = Time.now
script_filename = $0

knowns_csv_path = DEFAULT_KNOWNS_CSV_PATH if knowns_csv_path.nil?
output_zip_path = "#{script_filename.split(".rb").first}-#{start_time.to_i}.zip"
operations_csv_path = "#{script_filename.split(".rb").first}-#{start_time.to_i}.csv"

# Verify that expected files exist

[
    source_zip_path,
    destination_zip_path,
    knowns_csv_path
].each do |path|
    abort "Path not found: #{path}" unless File.exists? path
end


# Bring in the required libraries and modules

require "csv"
require "nokogiri"
require "rexml/document"
require "zip/zip"

require "./convenience.rb"
include Convenience

# The first order of business is that we need to compile a list of all known
# components or permissions in the destination org. This way, we'll be able
# to kill the permissions that aren't applicable and also add permissions
# that need to be explicitly set.

knowns = {
    APEX_CLASS_XML_NAME => [],
    APEX_PAGE_XML_NAME => [],
    CUSTOM_APPLICATION_XML_NAME => [],
    CUSTOM_OBJECT_XML_NAME => [],
    CUSTOM_TAB_XML_NAME => [],
    FIELDS_FIELD_NAME => [],
    LAYOUT_XML_NAME => [],
    RECORD_TYPES_FIELD_NAME => [],
    USER_PERMISSIONS_FIELD_NAME => []
}

# First, read the known components (easy)
# This file should include info on user permissions and standard tabs (a.k.a.
# custom tabs for purposes of the script)
#
# User permissions can be obtained by setting every single permission to true
# on a profile or permission set and then retrieving that component.
#
# Standard tab names are trickier: You'll have to turn on the new profile
# editor and then examine the links attached to the object navigation menu
# for switching between object settings when editing a profile.

header_row = nil
CSV.foreach(knowns_csv_path) do |row|
    if header_row.nil?
        header_row = row  # Assume headers: "Name", "Known Category"
    else
        if row[1] == CUSTOM_TAB_XML_NAME
            knowns[CUSTOM_TAB_XML_NAME].push row[0]
        elsif row[1] == USER_PERMISSIONS_FIELD_NAME
            knowns[USER_PERMISSIONS_FIELD_NAME].push row[0]
        else
            warning "Unknown known: #{row}"
        end
    end
end

# Next, let's tackle the package.xml file in our destination .zip file
# From here, we should be able to extract reliable lists (assuming you used
# retrieve-profiles.rb to retrieve this package) of custom objects,
# custom apps (no standard apps, sadly), Apex classes, Visualforce pages,
# and custom tabs (complimenting the standard ones we grabbed manually)

package_xml_listable_components = [
    APEX_CLASS_XML_NAME,
    APEX_PAGE_XML_NAME,
    CUSTOM_APPLICATION_XML_NAME,
    CUSTOM_OBJECT_XML_NAME,
    CUSTOM_TAB_XML_NAME,
    LAYOUT_XML_NAME,
    RECORD_TYPES_FIELD_NAME
]

Zip::ZipFile.foreach(destination_zip_path) do |zip_entry|
    #debug "Flipping to: #{zip_entry.name}"
    
    if zip_entry.name.end_with? PACKAGE_XML_FILENAME
        debug "Reading: #{zip_entry.name}"
        
        # Construct a REXML::Document from the XML file
        # This will allow us to more easily manipulate the contents
        
        package_doc = REXML::Document.new zip_entry.get_input_stream
        
        # Go through all of the types name elements and look for
        # ones that we recognize and need to compile
        
        package_doc.each_element("Package/types/name") do |name_el|
            metadata_object_name = name_el.get_text.to_s
            
            if package_xml_listable_components.include? metadata_object_name
                name_el.parent.each_element("members") do |members_el|
                    component_name = members_el.get_text.to_s
                    knowns[metadata_object_name].push component_name
                end
                debug "#{metadata_object_name} : #{knowns[metadata_object_name]}"
            end
        end
    end
end

# Okay, now comes one of two PITA's: Go through all of the .object files and
# extract every single encountered record type in there. Both FLS (a.k.a.
# field permissions) and page layout assignments rely on the full record type
# name, such as "Account-M%26D Master Profile". Oh yeah, the name is indeed
# URL-encoded.

Zip::ZipFile.foreach(destination_zip_path) do |zip_entry|
    if zip_entry.name.end_with? OBJECT_FILE_EXTENSION
        debug "Reading: #{zip_entry.name}"
        
        object_name = zip_entry.name.split("/").last.split(".").first
        
        # Construct a REXML::Document from the XML file
        # This will make life much easier
        
        # For some reason the expected construct doesn't work within the .zip
        # file. I may need to engage the Ruby community to figure out why
        #object_doc = REXML::Document.new zip_entry.get_input_stream
        
        # The below prints out the XML and then dies, with no indication what
        # the error was. I'm switching to Nokogiri to see if it fares better
        #object_doc = REXML::Document.new File.open(zip_entry.get_input_stream.read)
        
        object_doc = Nokogiri::XML::Document.parse zip_entry.get_input_stream
        
        # Go through all of the record type elements and add the full name
        # of each record type to our base of knowns
        
        object_doc.remove_namespaces!
        object_doc.xpath("CustomObject/recordTypes/fullName").each do |full_name_el|
            full_name = "#{object_name}.#{full_name_el.inner_text}"
            knowns[RECORD_TYPES_FIELD_NAME].push full_name
        end
    end
end

# Finally, one last PITA: Pull up the first profile that has a full Salesforce
# license, indicated by the userLicense field. Then, dig through that profile
# to compile a list of every single custom field in the system

Zip::ZipFile.foreach(destination_zip_path) do |zip_entry|
    if knowns[FIELDS_FIELD_NAME].empty?
        if zip_entry.name.end_with? PROFILE_FILE_EXTENSION
            debug "Reading: #{zip_entry.name}"
            
            # Read the XML into a NokogiriLLXML::Document
            # Life will be good
            
            profile_doc = Nokogiri::XML::Document.parse zip_entry.get_input_stream
            
            profile_doc.remove_namespaces!
            profile_doc.xpath("Profile/fieldPermissions/field").each do |field_el|
                knowns[FIELDS_FIELD_NAME].push "#{field_el.inner_text}"
            end
        end
    end
end

# Sweet! We are now more than halfway done with the script. All that remains
# are two steps. First, prune the source profiles. Second, generate the .zip
# package to deploy.

profiles = {}    # Prepared profiles we're going to repackage
log_rows = [
    [
        "Profile Name", 
        "XML Field Name", 
        "Component Name", 
        "Operation", 
        "Comments"
    ]
]  # The start of the CSV log of operations performed during preparation

Zip::ZipFile.foreach(source_zip_path) do |zip_entry|
    debug "Poking through #{source_zip_path}: #{zip_entry.name}"
    
    if zip_entry.name.end_with? PROFILE_FILE_EXTENSION
        debug "Preparing: #{zip_entry.name}"
        
        # Parse the profile name to use as the key for our profiles hash
        
        profile_name = zip_entry.name.split("/").last.split(".").first
        
        # Let's try REXML again... for ease of dealing with namespaces
        
        debug "Constructing document from XML..."
        profile_doc = REXML::Document.new zip_entry.get_input_stream
        
        # Step 1: Remove unrecognized applicationVisibilities elements
        
        xml_field_name = "applicationVisibilities"
        debug "Processing #{xml_field_name}..."
        profile_doc.each_element("Profile/#{xml_field_name}/application") do
            |el|
            
            component_name = el.get_text.to_s
            unless knowns[CUSTOM_APPLICATION_XML_NAME].include? component_name
                el.parent.parent.delete el.parent
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    component_name,
                    "Remove",
                    "Not in #{destination_zip_path}"
                ]
            end
        end
        
        # Step 2: Remove unrecognized classAccesses elements
        
        xml_field_name = "classAccesses"
        debug "Processing #{xml_field_name}..."
        profile_doc.each_element("Profile/#{xml_field_name}/apexClass") do
            |el|
            
            component_name = el.get_text.to_s
            unless knowns[APEX_CLASS_XML_NAME].include? component_name
                el.parent.parent.delete el.parent
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    component_name,
                    "Remove",
                    "Not in #{destination_zip_path}"
                ]
            end
        end
        
        # Step 3: Remove unrecognized fieldPermissions elements
        
        xml_field_name = "fieldPermissions"
        debug "Processing #{xml_field_name}..."
        profile_doc.each_element("Profile/#{xml_field_name}/field") do
            |el|
            
            component_name = el.get_text.to_s
            unless knowns[FIELDS_FIELD_NAME].include? component_name
                el.parent.parent.delete el.parent
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    component_name,
                    "Remove",
                    "Not in #{destination_zip_path}"
                ]
            end
        end
        
        # Step 4: Remove unrecognized layoutAssignments elements.
        # This needs to be approached from the availability of 
        # both the record type and the page layout
        
        xml_field_name = "layoutAssignments"
        debug "Processing #{xml_field_name}..."
        
        profile_doc.each_element("Profile/#{xml_field_name}/recordType") do
            |el|
            
            component_name = el.get_text.to_s
            unless knowns[RECORD_TYPES_FIELD_NAME].include? component_name
                el.parent.parent.delete el.parent
                
                layout_re_matches = el.parent.to_s.match(/<layout>([^<]*)<\/layout>/)
                record_type_re_matches = el.parent.to_s.match(/<recordType>([^<]*)<\/recordType>/)
                
                component_description = record_type_re_matches.nil? ? "#{layout_re_matches[1]} to --Master--" : "#{layout_re_matches[1]} to #{record_type_re_matches[1]}"
                
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    component_description,
                    "Remove",
                    "Record Type not in #{destination_zip_path}"
                ]
            end
        end
        
        profile_doc.each_element("Profile/#{xml_field_name}/layout") do
            |el|
            
            component_name = el.get_text.to_s
            unless knowns[LAYOUT_XML_NAME].include? component_name
                el.parent.parent.delete el.parent
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    el.parent.get_text.to_s,
                    "Remove",
                    "Page Layout not in #{destination_zip_path}"
                ]
            end
        end
        
        # Step 5: Remove unrecognized objectPermissions elements
        # We need to explicitly add elements for objects to which the profile
        # has no CRED access, because those are not returned by the system
        
        xml_field_name = "objectPermissions"
        debug "Processing #{xml_field_name}..."
        
        remaining_knowns = knowns[CUSTOM_OBJECT_XML_NAME].clone
        last_el = nil  # The last found element for this XML field
        
        profile_doc.each_element("Profile/#{xml_field_name}/object") do
            |el|
            
            component_name = el.get_text.to_s
            if remaining_knowns.include? component_name
                last_el = el.parent
                remaining_knowns.delete component_name
            else
                el.parent.parent.delete el.parent
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    component_name,
                    "Remove",
                    "Not in #{destination_zip_path}"
                ]
            end
        end
        
        remaining_knowns.each do |component_name|
            profile_el = profile_doc.root
            xml_field_el = REXML::Element.new xml_field_name
            
            children = {
                "allowCreate" => false,
                "allowDelete" => false,
                "allowEdit" => false,
                "allowRead" => false,
                "modifyAllRecords" => false,
                "object" => component_name,
                "viewAllRecords" => false
            }
            
            children.each do |key, value|
                xml_field_child_el = REXML::Element.new key, xml_field_el
                xml_field_child_el.add_text "#{value}"
            end
            
            profile_el.insert_after last_el, xml_field_el
            last_el = xml_field_el
            
            log_rows.push [
                profile_name,
                xml_field_name,
                component_name,
                "Add",
                "Not in #{destination_zip_path}; chmod -CREDVM"
            ]
        end
        
        # Step 6: Remove unrecognized pageAccesses
        
        xml_field_name = "pageAccesses"
        debug "Processing #{xml_field_name}..."
        profile_doc.each_element("Profile/#{xml_field_name}/apexPage") do
            |el|
            
            component_name = el.get_text.to_s
            unless knowns[APEX_PAGE_XML_NAME].include? component_name
                el.parent.parent.delete el.parent
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    component_name,
                    "Remove",
                    "Not in #{destination_zip_path}"
                ]
            end
        end
        
        # Step 7: Remove unrecognized recordTypeVisibilities elements
        
        xml_field_name = "recordTypeVisibilities"
        debug "Processing #{xml_field_name}..."
        
        profile_doc.each_element("Profile/#{xml_field_name}/recordType") do
            |el|
            
            component_name = el.get_text.to_s
            unless knowns[RECORD_TYPES_FIELD_NAME].include? component_name
                el.parent.parent.delete el.parent
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    component_name,
                    "Remove",
                    "Not in #{destination_zip_path}"
                ]
            end
        end
        
        # Step 8: Remove unrecognized tabVisibilities elements
        # We need to explicitly add in elements for tabs that are hidden
        # to the profile, because those don't show up in the metadata
        
        xml_field_name = "tabVisibilities"
        debug "Processing #{xml_field_name}..."
        
        remaining_knowns = knowns[CUSTOM_TAB_XML_NAME].clone
        last_el = nil  # The last found element for this XML field
        
        profile_doc.each_element("Profile/#{xml_field_name}/tab") do
            |el|
            
            component_name = el.get_text.to_s
            if remaining_knowns.include? component_name
                last_el = el.parent
                remaining_knowns.delete component_name
            else
                el.parent.parent.delete el.parent
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    component_name,
                    "Remove",
                    "Not in #{destination_zip_path}"
                ]
            end
        end
        
        remaining_knowns.each do |component_name|
            profile_el = profile_doc.root
            xml_field_el = REXML::Element.new xml_field_name
            
            children = {
                "tab" => component_name,
                "visibility" => "Hidden"
            }
            
            children.each do |key, value|
                xml_field_child_el = REXML::Element.new key, xml_field_el
                xml_field_child_el.add_text "#{value}"
            end
            
            profile_el.insert_after last_el, xml_field_el
            last_el = xml_field_el
            
            log_rows.push [
                profile_name,
                xml_field_name,
                component_name,
                "Add",
                "Not in #{destination_zip_path}; chmod Hidden"
            ]
        end
        
        # Step 9: Explicitly add disabled userPermissions elements
        
        xml_field_name = "userPermissions"
        debug "Processing #{xml_field_name}..."
        
        remaining_knowns = knowns[USER_PERMISSIONS_FIELD_NAME].clone
        last_el = nil  # The last found element for this XML field
        
        profile_doc.each_element("Profile/#{xml_field_name}/name") do
            |el|
            
            component_name = el.get_text.to_s
            if remaining_knowns.include? component_name
                last_el = el.parent
                remaining_knowns.delete component_name
            end
        end
        
        remaining_knowns.each do |component_name|
            profile_el = profile_doc.root
            xml_field_el = REXML::Element.new xml_field_name
            
            children = {
                "enabled" => false,
                "name" => component_name
            }
            
            children.each do |key, value|
                xml_field_child_el = REXML::Element.new key, xml_field_el
                xml_field_child_el.add_text "#{value}"
            end
            
            profile_el.insert_after last_el, xml_field_el
            last_el = xml_field_el
            
            log_rows.push [
                profile_name,
                xml_field_name,
                component_name,
                "Add",
                "Not in #{destination_zip_path}; chmod enabled=false"
            ]
        end
        
        # Step THG: We don't want to change the loginHours or loginIpRanges
        # settings, which would break the "lock" we have on the system during
        # deployment weekend, 12/13/2013-12/15/2013.
        
        xml_field_names = ["loginHours", "loginIpRanges"]
        
        xml_field_names.each do |xml_field_name|
            debug "Processing #{xml_field_name}..."
            
            profile_doc.each_element("Profile/#{xml_field_name}") do
                |el|
                
                component_name = el.get_text.to_s
                el.parent.delete el
                
                log_rows.push [
                    profile_name,
                    xml_field_name,
                    "n/a",
                    "Remove",
                    "Let's not change this in the destination org"
                ]
            end
        end
        
        profiles[profile_name] = profile_doc
    end # zip_entry.name.end_with? PROFILE_FILE_EXTENSION
end

# Instantiate the output .zip package

output_zip_file = Zip::ZipFile.open(output_zip_path, Zip::ZipFile::CREATE)

# Create the individual .profile files for each profile within the .zip file

profiles.each do |profile_name, profile|
    output_zip_file.get_output_stream("profiles/#{profile_name}.profile") do |f|
        profile.write(f)
    end
end

# Create the package.xml file
#
# <?xml version="1.0" encoding="UTF-8"?>
# <Package xmlns="http://soap.sforce.com/2006/04/metadata">
#     <types>
#         <members>M%26D%3A PL Sales</members>
#         <name>Profile</name>
#     </types>
#     <version>29.0</version>
# </Package>

package_decl = REXML::XMLDecl.new("1.0", "UTF-8")
package_doc = REXML::Document.new
package_doc.add package_decl

package_el = REXML::Element.new("Package", package_doc)
package_el.add_attribute "xmlns", "http://soap.sforce.com/2006/04/metadata"

profile_types_el = REXML::Element.new("types", package_el)

profiles.keys.each do |profile_name|
    profile_members_el = REXML::Element.new("members", profile_types_el)
    profile_members_el.add_text profile_name
end

profile_types_name_el = REXML::Element.new("name", profile_types_el)
profile_types_name_el.add_text "Profile"

version_el = REXML::Element.new("version", package_el)
version_el.add_text "29.0"

output_zip_file.get_output_stream("package.xml") do |f|
    package_doc.write(f)
end

# Close the output .zip package

output_zip_file.close

# Produce the operations log

CSV.open(operations_csv_path, "wb") do |csv|
    log_rows.each do |row|
        csv << row
    end
end

# Final note to self

knowns.each do |key, a|
    debug "#{key}: #{knowns[key].size} values"
    #debug a
end
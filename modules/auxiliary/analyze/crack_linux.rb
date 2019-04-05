##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core/auxiliary/password_cracker'

class MetasploitModule < Msf::Auxiliary
  include Msf::Auxiliary::PasswordCracker

  def initialize
    super(
      'Name'            => 'Password Cracker: Linux',
      'Description'     => %Q{
          This module uses John the Ripper or Hashcat to identify weak passwords that have been
        acquired from unshadowed passwd files from Unix/Linux systems. The module will only crack
        MD5, BSDi and DES implementations by default. However, it can also crack
        Blowfish and SHA(256/512), but it is much slower.
      },
      'Author'          =>
        [
          'theLightCosine',
          'hdm',
          'h00die' # hashcat integration
        ] ,
      'License'         => MSF_LICENSE,  # JtR itself is GPLv2, but this wrapper is MSF (BSD)
      'Actions'         =>
        [
          ['john', {'Description' => 'Use John the Ripper'}],
          ['hashcat', {'Description' => 'Use Hashcat'}],
        ],
      'DefaultAction' => 'john',
    )

    register_options(
      [
        OptBool.new('MD5',[false, 'Include MD5 hashes', true]),
        OptBool.new('DES',[false, 'Indlude DES hashes', true]),
        OptBool.new('BSDI',[false, 'Include BSDI hashes', true]),
        OptBool.new('BLOWFISH',[false, 'Include BLOWFISH hashes (Very Slow)', false]),
        OptBool.new('SHA256',[false, 'Include SHA256 hashes (Very Slow)', false]),
        OptBool.new('SHA512',[false, 'Include SHA512 hashes (Very Slow)', false])
      ]
    )

  end

  def show_command(cracker_instance)
    if datastore['ShowCommand']
      if action.name == 'john'
        cmd = cracker_instance.john_crack_command
      elsif action.name == 'hashcat'
        cmd = cracker_instance.hashcat_crack_command
      end
      print_status("   Cracking Command: #{cmd.join(' ')}")
    end
  end

  def print_results(tbl, cracked_hashes)
    cracked_hashes.each do |row|
      unless tbl.rows.include? row
        tbl << row
      end
    end
    tbl.to_s
  end

  def run
    def process_crack(results, hashes, cred, hash_type, method)
      return results if cred['core_id'].nil? # make sure we have good data
      # make sure we dont add the same one again
      add_it = true

      results.each do |r|
        if r[0] == cred['core_id']
          add_it = false
          break
        end
      end

      results << [cred['core_id'], hash_type, cred['username'], cred['password'], method] if add_it
      create_cracked_credential( username: cred['username'], password: cred['password'], core_id: cred['core_id'])
      results
    end

    def check_results(passwords, results, hash_type, hashes, method)
      passwords.each do |password_line|
        password_line.chomp!
        next if password_line.blank?
        fields = password_line.split(":")
        # If we don't have an expected minimum number of fields, this is probably not a hash line
        if action.name == 'john'
          next unless fields.count >=3
          cred = {}
          cred['username'] = fields.shift
          cred['core_id']  = fields.pop
          4.times { fields.pop } # Get rid of extra :
          cred['password'] = fields.join(':') # Anything left must be the password. This accounts for passwords with semi-colons in it
          results = process_crack(results, hashes, cred, hash_type, method)
        elsif action.name == 'hashcat'
          next unless fields.count >= 2
          hash = fields.shift
          password = fields.join(':') # Anything left must be the password. This accounts for passwords with : in them
          next if hash.include?("Hashfile '") && hash.include?("' on line ") # skip error lines
          hashes.each do |h|
            next unless h['hash'] == hash
            cred = {'core_id' => h['id'],
                    'username' => h['un'],
                    'password' => password}
            results = process_crack(results, hashes, cred, hash_type, method)
          end
        end
      end
      results
    end

    tbl = Rex::Text::Table.new(
      'Header'  => 'Cracked Hashes',
      'Indent'   => 1,
      'Columns' => ['DB ID', 'Hash Type', 'Username', 'Cracked Password', 'Method']
    )

    # array of hashes in jtr_format in the db, converted to an OR combined regex
    hashes_regex = []
    hashes_regex << 'md5crypt' if datastore['MD5']
    hashes_regex << 'descrypt' if datastore['DES']
    hashes_regex << 'bsdicrypt' if datastore['BSDI']
    hashes_regex << 'bcrypt' if datastore['BLOWFISH']
    hashes_regex << 'sha256crypt' if datastore['SHA256']
    hashes_regex << 'sha512crypt' if datastore['SHA512']
    #if action.name == 'john'
    #  # hashcat doesn't do generic crypt(3)
    #  hashes_regex |= ['crypt', 'bcrypt'] if datastore['Crypt'] #blowfish is not within the 'crypt' family
    #elsif action.name == 'hashcat'
    #end

    # array of arrays for cracked passwords.
    # Inner array format: db_id, hash_type, username, password, method_of_crack
    results = []

    cracker = new_password_cracker
    cracker.cracker = action.name

    print_good("#{action.name} Version Detected: #{cracker.cracker_version}")

    # create the hash file first, so if there aren't any hashes we can quit early
    # hashes is a reference list used by hashcat only
    cracker.hash_path, hashes = hash_file(hashes_regex)

    # generate our wordlist and close the file handle.
    wordlist = wordlist_file
    unless wordlist
      print_error('This module cannot run without a database connected. Use db_connect to connect to a database.')
      return
    end

    wordlist.close
    print_status "Wordlist file written out to #{wordlist.path}"
    cracker.wordlist = wordlist.path

    cleanup_files = [cracker.hash_path, wordlist.path]

    # JtR bulks 
    hashes_regex.each do |format|
      # dupe our original cracker so we can safely change options between each run
      cracker_instance = cracker.dup
      cracker_instance.format = format
      if action.name == 'john'
        cracker_instance.fork = datastore['FORK']
      end

      # first check if anything has already been cracked so we don't report it incorrectly
      print_status "Checking #{format} hashes already cracked..."
      results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Already Cracked/POT')
      vprint_good(print_results(tbl, results))

      if action.name == 'john'
        print_status "Cracking #{format} hashes in normal mode"
        cracker_instance.wordlist = ''
        show_command cracker_instance
        cracker_instance.crack do |line|
          vprint_status line.chomp
        end
        results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Normal')
        vprint_good(print_results(tbl, results))
      end

      print_status "Cracking #{format} hashes in wordlist mode..."
      if action.name == 'john'
        # Turn on KoreLogic rules if the user asked for it
        if datastore['KORELOGIC']
          cracker_instance.rules = 'KoreLogicRules'
          print_status "Applying KoreLogic ruleset..."
        end
      end
      show_command cracker_instance
      cracker_instance.crack do |line|
        vprint_status line.chomp
      end

      results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Wordlist')
      vprint_good(print_results(tbl, results))

      if action.name == 'john'
        print_status "Cracking #{format} hashes in single mode..."
        cracker_instance.rules = 'single'
        show_command cracker_instance
        cracker_instance.crack do |line|
          vprint_status line.chomp
        end

        results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Single')
        vprint_good(print_results(tbl, results))
      end

      print_status "Cracking #{format} hashes in incremental mode..."
      if action.name == 'john'
        cracker_instance.rules = nil
        cracker_instance.wordlist = nil
        cracker_instance.incremental = 'Digits'
      elsif action.name == 'hashcat'
        cracker_instance.wordlist = nil
        cracker_instance.attack = '3'
        cracker_instance.incremental = true
      end
      show_command cracker_instance
      cracker_instance.crack do |line|
        vprint_status line.chomp
      end

      results = check_results(cracker_instance.each_cracked_password, results, format, hashes, 'Incremental')
      # not vprint here since its the last one
      print_good(print_results(tbl, results))
    end
    if datastore['DeleteTempFiles']
      cleanup_files.each do |f|
        File.delete(f)
      end
    end
  end

  def hash_file(hashes_regex)
    hashes = []
    wrote_hash = false
    hashlist = Rex::Quickfile.new("hashes_tmp")
    # Convert names from JtR to DB
    hashes_regex = hashes_regex.join('|')\
              .gsub('md5crypt', 'md5')\
              .gsub('descrypt', 'des')\
              .gsub('bsdicrypt', 'bsdi')\
              .gsub('sha256crypt', 'sha256')\
              .gsub('sha512crypt', 'sha512')\
              .gsub('bcrypt', 'bf')
    regex = Regexp.new hashes_regex
    framework.db.creds(workspace: myworkspace, type: 'Metasploit::Credential::NonreplayableHash').each do |core|
      if core.private.jtr_format =~ regex
        if action.name == 'john'
          hashlist.puts hash_to_jtr(core)
        elsif action.name == 'hashcat'
          # hashcat hash files dont include the ID to reference back to so we build an array to reference
          hashes << {'hash' => core.private.data, 'un' => core.public.username, 'id' => core.id}
          hashlist.puts hash_to_hashcat(core)
        end
        wrote_hash = true
      end
    end
    hashlist.close
    unless wrote_hash # check if we wrote anything and bail early if we didn't
      hashlist.delete
      fail_with Failure::NotFound, 'No applicable hashes in database to crack'
    end
    print_status "Hashes Written out to #{hashlist.path}"
    return hashlist.path, hashes
  end
end

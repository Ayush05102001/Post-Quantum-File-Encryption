#!/usr/bin/env bash
# =====================================================================
#  RECEIVER SIDE  -  Linux VM
#  Post-quantum file sharing with ML-KEM-768
#
#  How to use this file:
#    Type the commands one part at a time. Do not run the whole file
#    at once, because the work goes back and forth between two machines.
#
#    Order of work:
#      Part 1 and Part 2   -> here, on the Linux VM
#      Part 3 to Part 6    -> on the Mac (file: sender_macos.sh)
#      Part 7 to Part 11   -> back here, on the Linux VM
# =====================================================================


# =====================================================================
#  PART 1: Get the Linux VM ready
# =====================================================================

# See which OpenSSL we have. It must be 3.5 or newer.
openssl version

# Check that OpenSSL knows ML-KEM. We want to see ML-KEM-768 in the list.
openssl list -kem-algorithms | grep -i ml-kem

# Install the small tools we need.
#   zip and unzip  -> to open the box of files (the archive)
#   xxd            -> to turn key files into hex text that OpenSSL can read
#   openssh-server -> so the Mac can copy files to and from this VM
sudo apt install -y zip unzip xxd openssh-server

# Make a folder for the project and go into it.
mkdir ~/lab2
cd ~/lab2


# =====================================================================
#  PART 2: Make the key pair for the receiver
# =====================================================================

# Make the private key. This is the secret key. It never leaves this VM.
openssl genpkey -algorithm ML-KEM-768 -out receiver1.kem.priv

# Make the public key from the private key. This one is safe to share. The sender needs it.
openssl pkey -in receiver1.kem.priv -pubout -out receiver1.kem.pub

# Lock the private key so only we can read it.
chmod 600 receiver1.kem.priv

# Look at the two new files.
ls -l
cat receiver1.kem.pub

# Find the address and user name of this VM. Write both down. The Mac needs them to reach the VM.
hostname -I
whoami

# ---------------------------------------------------------------------
#  NOW GO TO THE MAC.
#  Open sender_macos.sh and do Part 3 to Part 6.
#  Come back here when the Mac has sent archive.zip to this VM.
# ---------------------------------------------------------------------


# =====================================================================
#  PART 7: Open the archive from the sender
# =====================================================================

# Go to the project folder. archive.zip should be here now.
cd ~/lab2
ls -l archive.zip

# Make a work folder and unpack the archive into it.
mkdir rx
cd rx
unzip ../archive.zip

# We should see 5 files:
#   file1.enc     -> the locked file
#   iv.hex        -> a random start value for the file lock (not secret)
#   kem1.bin      -> the KEM ciphertext, made for our public key
#   envelope1.bin -> the locked file key
#   tag1.bin      -> a check value that proves the envelope is ours and not changed
ls -l


# =====================================================================
#  PART 8: Get the shared secret back and check the tag
# =====================================================================

# Use our private key on kem1.bin.
# This gives back the same 32 byte secret the Mac had.
openssl pkeyutl -decap -inkey ../receiver1.kem.priv -in kem1.bin -out ss.bin

# Put the secret in a short-lived variable as hex text.
SS=$(xxd -p -c 256 ss.bin)

# Make the MAC key from the secret, the same way the Mac did. The label LAB2-mac makes sure this key is different from the others.
openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt hexkey:$SS -kdfopt info:LAB2-mac -binary -out mac.bin HKDF

# Make our own tag for the envelope.
openssl dgst -sha256 -mac HMAC -macopt hexkey:"$(xxd -p -c 256 mac.bin)" -binary -out mytag.bin envelope1.bin

# Compare our tag with the tag from the sender. If they are the same, the envelope is for us and nobody changed it.
# Important: ML-KEM never says "wrong key". With a wrong key it just gives a different secret. So this tag check is how we know.
cmp mytag.bin tag1.bin && echo "TAG MATCHES - this envelope is ours"


# =====================================================================
#  PART 9: Open the envelope and unlock the file
# =====================================================================

# Make the envelope key (KEK) and envelope IV from the same secret. The label LAB2-kek gives 48 bytes.
openssl kdf -keylen 48 -kdfopt digest:SHA256 -kdfopt hexkey:$SS -kdfopt info:LAB2-kek -binary -out kek_iv.bin HKDF

# We are done with the secret in the variable, so wipe it.
unset SS

# Cut the 48 bytes in two parts:
#   first 32 bytes -> the envelope key (KEK) & last 16 bytes  -> the envelope IV
head -c 32 kek_iv.bin > kek.bin
tail -c 16 kek_iv.bin > eiv.bin

# Open the envelope. This gives back the 32 byte file key.
openssl enc -d -aes-256-ctr -K "$(xxd -p -c 256 kek.bin)" -iv "$(xxd -p -c 256 eiv.bin)" -in envelope1.bin -out fek.bin

# Check that the file key is 32 bytes.
ls -l fek.bin

# Unlock the file with the file key. The file here would be stored as recovered_file1
openssl enc -d -aes-256-ctr -K "$(xxd -p -c 256 fek.bin)" -iv "$(cat iv.hex)" -in file1.enc -out ../recovered_file1


# =====================================================================
#  PART 10: Delete all secrets on the VM
# =====================================================================

# The work folder has the secret, the keys and the file key. shred writes over each file before it deletes it.
shred -u ss.bin mac.bin mytag.bin kek_iv.bin kek.bin eiv.bin fek.bin

# Leave the work folder and remove it.
cd ~/lab2
rm -rf rx


# =====================================================================
#  PART 11 (extra): See what happens with a wrong key
# =====================================================================

# Make a second key that is not for this archive.
openssl genpkey -algorithm ML-KEM-768 -out stranger.kem.priv

# Unpack the archive again into a test folder.
mkdir test
cd test
unzip ../archive.zip

# Try to get the secret with the wrong key.
openssl pkeyutl -decap -inkey ../stranger.kem.priv -in kem1.bin -out wrong_ss.bin

# Show the exit code. It is 0, which means "no error". ML-KEM does not tell us the key is wrong.
echo $?

# Look at the secret. It looks normal, but it is wrong.
xxd -p -c 64 wrong_ss.bin

# Make a MAC key and a tag from the wrong secret, and compare.
SS=$(xxd -p -c 256 wrong_ss.bin)
openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt hexkey:$SS -kdfopt info:LAB2-mac -binary -out mac.bin HKDF
unset SS
openssl dgst -sha256 -mac HMAC -macopt hexkey:"$(xxd -p -c 256 mac.bin)" -binary -out mytag.bin envelope1.bin

# This time the tags are not the same. This is how the receiver finds
# out the archive is not for this key.
cmp mytag.bin tag1.bin || echo "TAG DOES NOT MATCH - this envelope is not for this key"

# Clean up the test.
cd ~/lab2
rm -rf test
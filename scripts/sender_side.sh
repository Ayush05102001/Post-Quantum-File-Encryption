#!/usr/bin/env bash
# =====================================================================
#  SENDER SIDE  -  macOS
#  Post-quantum file sharing with ML-KEM-768
#
#  How to use this file:
#    Type the commands one part at a time. Do not run the whole file
#    at once, because the work goes back and forth between two machines.
#
#    Order of work:
#      Part 1 and Part 2   -> on the Linux VM (file: receiver_linux_vm.sh)
#      Part 3 to Part 6    -> here, on the Mac
#      Part 7 to Part 11   -> on the Linux VM
#
# =====================================================================


# =====================================================================
#  PART 3: Get the Mac ready and get the receiver's public key
# =====================================================================

# The Mac comes with LibreSSL, which does not have ML-KEM. So we install the real OpenSSL with Homebrew.
brew install openssl@3

# Check the version. It must say OpenSSL 3.5 or newer, not LibreSSL.
openssl version

# Check that ML-KEM-768 is in the list.
openssl list -kem-algorithms | grep -i ml-kem

# Make a folder for the project and go into it.
mkdir ~/lab2
cd ~/lab2

# Copy the receiver's PUBLIC key from the VM to the Mac using scp command.
# We only copy the .pub file. The private key stays on the VM.
scp VMUSER@VMIP:~/lab2/receiver1.kem.pub ~/lab2/
ls -l


# =====================================================================
#  PART 4: Lock (encrypt) the file
# =====================================================================

# Make a test file.(You can use any file. Just name it file1.). You can also use nano to create a simple .txt file for testing purpose
head -c 102400 /dev/urandom > file1

# Make a work folder, so all the secret files stay in one place.
mkdir work
cd work

# Make the file key: 32 random bytes. This is an AES-256 key.
openssl rand -out fek.bin 32

# Make the IV: 16 random bytes, saved as hex text.
# The IV is not secret. It travels with the file.
openssl rand -hex 16 > iv.hex

# Lock the file with AES-256-CTR using the file key and the IV.
# -K (big K) means "here is the real key in hex".
# Small -k would treat it like a password, which is wrong here.
openssl enc -aes-256-ctr -K "$(xxd -p -c 256 fek.bin)" -iv "$(cat iv.hex)" -in ../file1 -out file1.enc

# Check: both files are the same size.
# The locked file must NOT start with the word "Salted__".
ls -l ../file1 file1.enc
head -c 8 file1.enc | xxd


# =====================================================================
#  PART 5: Make the envelope for the receiver
# =====================================================================

# Use the receiver's public key to make two things:
#   kem1.bin -> the KEM ciphertext. This goes to the receiver.
#   ss1.bin  -> a 32 byte shared secret. This stays on the Mac.
# Only the receiver's private key can turn kem1.bin back into the secret.
openssl pkeyutl -encap -pubin -inkey ../receiver1.kem.pub -out kem1.bin -secret ss1.bin

# Check the sizes: kem1.bin is 1088 bytes, ss1.bin is 32 bytes.
ls -l kem1.bin ss1.bin

# Put the secret in a short-lived variable as hex text.
SS=$(xxd -p -c 256 ss1.bin)

# We do not use the secret as a key straight away. HKDF turns it into new keys. A different label gives a different key.
# Label LAB2-kek -> 48 bytes: the envelope key (KEK) and the envelope IV
openssl kdf -keylen 48 -kdfopt digest:SHA256 -kdfopt hexkey:$SS -kdfopt info:LAB2-kek -binary -out kek_iv.bin HKDF

# Label LAB2-mac -> 32 bytes: the MAC key, used for the tag
openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt hexkey:$SS -kdfopt info:LAB2-mac -binary -out mac1.bin HKDF

# We are done with the secret in the variable, so remove it.
unset SS

# Cut the 48 bytes in two parts:
# first 32 bytes -> the envelope key (KEK) & last 16 bytes  -> the envelope IV
head -c 32 kek_iv.bin > kek1.bin
tail -c 16 kek_iv.bin > eiv1.bin

# Lock the file key inside the envelope, using the KEK and envelope IV.
openssl enc -aes-256-ctr -K "$(xxd -p -c 256 kek1.bin)" -iv "$(xxd -p -c 256 eiv1.bin)" -in fek.bin -out envelope1.bin

# Make the tag: an HMAC over the envelope, using the MAC key.
# The receiver uses this tag to know the envelope is theirs and that nobody changed it.
openssl dgst -sha256 -mac HMAC -macopt hexkey:"$(xxd -p -c 256 mac1.bin)" -binary -out tag1.bin envelope1.bin


# =====================================================================
#  PART 6: Delete the secrets, pack the archive and send it
# =====================================================================

# Delete every secret. rm -P writes over each file before deleting it. This matters: any one of these files plus the archive can open the file.
rm -P fek.bin ss1.bin kek_iv.bin kek1.bin eiv1.bin mac1.bin

# Only 5 files should be left, and none of them is secret:
#   file1.enc  iv.hex  kem1.bin  envelope1.bin  tag1.bin
ls -l

# Pack the 5 files into one archive.
# -j means "no folders inside the zip, just the files".
zip -j ../archive.zip file1.enc iv.hex kem1.bin envelope1.bin tag1.bin

# Go back, look inside the archive, and remove the work folder.
cd ..
unzip -l archive.zip
rm -rf work

# Send the archive to the VM.
scp ~/lab2/archive.zip VMUSER@VMIP:~/lab2/

# ---------------------------------------------------------------------
#  NOW GO BACK TO THE LINUX VM.
#  Open receiver_linux_vm.sh and continue with Part 7.
# ---------------------------------------------------------------------

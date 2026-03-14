we are making claude teleport 

in a local directory,r un the teleport command with a claude session hash, it copies the relative claude logs into remote storage, assume there isa  running vm instance. copies the claude directory, copies all required stuff for claude to run, including the project directory. 

claude resumes running, directory needs to be named the exact same thing. 

one vm, multiple projects. same working directory name!, i can teleport mulpitle sessions, have multiple claudes running in teleport mode, as long as we carefully get the filepaths right. 

this is just a claude plugin, /teleport once you set it up once then whenever you run that command it ports the session to our remote vm. probably best to make it cloud agnostic in design, then users can config what they want, like if they want modal or fly.io or gcp etc. for me I want to use fly.io btw



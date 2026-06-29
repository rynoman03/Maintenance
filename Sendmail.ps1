#Created by Ryan Cashier 05.2016 v1.0
#Change information inside "" and may need to remove <>'s.
#Used in conjuction with windows task scheduler to reboot a windows system and send an email when triggered. 
send-mailmessage -from "ServerName <ServerName@domain.com>" -to "Whoever <whoever@domain.com>", "Somebody <somebody@domain.com>" -subject "Server is rebooting" -body "Server is rebooting for application maintenance" -priority High -dno onSuccess, onFailure -smtpServer your.smtp.address.domain.com

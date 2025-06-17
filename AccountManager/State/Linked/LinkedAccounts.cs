using AbstractAccountApi;
using AccountManager.Action.StudentAccount;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class Accounts
    {
        public Dictionary<string, LinkedAccount> List = new Dictionary<string, LinkedAccount>();

        int totalWisaAccounts = 0;
        public int TotalWisaAccounts => totalWisaAccounts;

        int totalSmartschoolAccounts = 0;
        public int TotalSmartschoolAccounts => totalSmartschoolAccounts;

        int totalAzureAccounts = 0;
        public int TotalAzureAccounts => totalAzureAccounts;

        int unlinkedWisaAccounts = 0;
        public int UnlinkedWisaAccounts => unlinkedWisaAccounts;

        int unlinkedSmartschoolAccounts = 0;
        public int UnlinkedSmartschoolAccounts => unlinkedSmartschoolAccounts;

        int unlinkedAzureAccounts = 0;
        public int UnlinkedAzureAccounts => unlinkedAzureAccounts;

        int linkedWisaAccounts = 0;
        public int LinkedWisaAccounts => linkedWisaAccounts;

        int linkedSmartschoolAccounts = 0;
        public int LinkedSmartschoolAccounts => linkedSmartschoolAccounts;

        int linkedAzureAccounts = 0;
        public int LinkedAzureAccounts => linkedAzureAccounts;

        public async Task ReLink()
        {
            await Task.Run(() => DoRelink()).ConfigureAwait(false);
            App.Instance.Linked.UpdateObservers();
        }

        private void DoRelink()
        {
            if (AccountApi.Smartschool.GroupManager.Root == null) return;

            List.Clear();

            // first add all smartschool accounts to List. These will have the mail address as the key in List.
            var lln = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if (lln != null)
            {
                AddSmartschoolAccounts(lln);
            }

            /**
             * Wisa does not have the mail addresses, but smartschool has the wisa ID. We try to find the smartschool
             * account with the correct wisa ID. Then we will use the smartschool account to get the mail address,
             * which will be the key of the dictionary (List).
             * **/
            

            // iterate over all wisa accounts
            foreach(var account in AccountApi.Wisa.Students.All)
            {
                bool linked = false;                

                // search for match by wisa ID
                var smartschoolMatch = (lln as AccountApi.Smartschool.Group).FindAccountByWisaID(account.WisaID);

                // most of there time there is a smartschool match and it will have the user's mail.
                if (smartschoolMatch != null)
                {
                    // if the list contains the mail address as key
                    if (List.ContainsKey(smartschoolMatch.Mail))
                    {
                        // add the wisa account to this entry
                        List[smartschoolMatch.Mail].Wisa.Account = account;
                        linked = true;
                    }
                }

                /** 
                 * If the account is not linked at this point, the account does not exist in smartschool, but only in Wisa.
                 * For now it will be added with the WisaID as a key. This means a new key must probably be generated later.
                 * **/
                if (!linked)
                {
                    List.Add(account.WisaID, new LinkedAccount(account));
                }
            }

            /**
             * Now link azure accounts. These have a mail address and a wisa ID.
             * If the dict contains the key (mail) we do check for the wisa ID. It must be identical, in wich case the account is linked.
             * If not, this is a student with the same name as an existing student.
             * In this case we check if the list contains the Wisa ID. This will be true if the user exists in Wisa, But not in smartschool.
             * If the account does only exist in Azure, this is someone from another school. So this account can be discarded.
             * **/
            foreach (var account in AccountApi.Azure.UserManager.Instance.Users)
            {
                bool found = false;
                if (account.UserPrincipalName != null)
                {
                    if (List.ContainsKey(account.UserPrincipalName))
                    {
                        if (List[account.UserPrincipalName].Wisa.Account != null && List[account.UserPrincipalName].Wisa.Account.WisaID == account.EmployeeId)
                        {
                            List[account.UserPrincipalName].Azure.Account = account;
                            found = true;
                        }
                    }
                    if (!found && account.EmployeeId != null)
                    {
                        if (List.ContainsKey(account.EmployeeId))
                        {
                            List[account.EmployeeId].Azure.Account = account;
                            List.Add(account.UserPrincipalName, List[account.EmployeeId]);
                            List.Remove(account.EmployeeId);
                            found = true;
                        }
                    }
                     
                    if (!found) 
                    { 
                        foreach (var linkedAccount in List)
                        {
                            if (linkedAccount.Value.Wisa.Account != null && linkedAccount.Value.Wisa.Account.WisaID.Equals(account.EmployeeId)) {
                                linkedAccount.Value.Azure.Account = account;
                                found = true;
                                break;
                            }
                        }
                    }

                }
                
            }

            // count 
            totalWisaAccounts = totalSmartschoolAccounts = totalAzureAccounts = 0;
            unlinkedWisaAccounts = unlinkedSmartschoolAccounts = unlinkedAzureAccounts = 0;
            linkedWisaAccounts = linkedSmartschoolAccounts = linkedAzureAccounts = 0;

            foreach (var group in List.Values)
            {
                if (group == null) continue;
                bool incomplete = (!group.Wisa.Exists || !group.Smartschool.Exists || !group.Azure.Exists);
                if (group.Wisa.Exists)
                {
                    totalWisaAccounts++;
                    if (incomplete) unlinkedWisaAccounts++;
                    else linkedWisaAccounts++;
                }
                if (group.Smartschool.Exists)
                {
                    totalSmartschoolAccounts++;
                    if (incomplete) unlinkedSmartschoolAccounts++;
                    else linkedSmartschoolAccounts++;
                }
                if (group.Azure.Exists)
                {
                    totalAzureAccounts++;
                    if (incomplete) unlinkedAzureAccounts++;
                    else linkedAzureAccounts++;
                }
            }

            // add actions
            foreach (var account in List.Values)
            {
                AccountActionParser.AddActions(account);
            }
        }

        private void AddSmartschoolAccounts(AccountApi.IGroup group)
        {
            foreach(var account in group.Accounts)
            {
                string key = FindKey(account);
                if(key != null)
                {
                    List[key].Smartschool.Account = account as AccountApi.Smartschool.Account;
                } else
                {
                    List.Add(account.Mail, new LinkedAccount(account as AccountApi.Smartschool.Account));
                }
            }

            if(group.Children != null)
            foreach(var child in group.Children)
            {
                AddSmartschoolAccounts(child);
            }
        }

        private string FindKey(AccountApi.IAccount account)
        {
            if (List.ContainsKey(account.Mail)) return account.Mail;
            foreach (var entry in List)
            {
                if (entry.Value.Wisa.Account != null && entry.Value.Wisa.Account.WisaID == account.AccountID)
                {
                    return entry.Key;
                } 
            }
            return null;
        }
    }
}

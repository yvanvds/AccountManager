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

            var lln = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if (lln != null)
            {
                AddSmartschoolAccounts(lln);
            }

            foreach(var account in AccountApi.Wisa.Students.All)
            {
                bool linked = false;

                var smartschoolMatch = (lln as AccountApi.Smartschool.Group).FindAccountByWisaID(account.WisaID);

                if (smartschoolMatch != null)
                {
                    if (List.ContainsKey(smartschoolMatch.Mail))
                    {
                        List[smartschoolMatch.Mail].Wisa.Account = account;
                        linked = true;
                    }
                }

                if (!linked)
                {
                    List.Add(account.WisaID, new LinkedAccount(account));
                }
            }

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
                    if (!found) {
                        
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

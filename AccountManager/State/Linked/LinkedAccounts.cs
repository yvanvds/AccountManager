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

        int totalDirectoryAccounts = 0;
        public int TotalDirectoryAccounts => totalDirectoryAccounts;

        int totalSmartschoolAccounts = 0;
        public int TotalSmartschoolAccounts => totalSmartschoolAccounts;

        int totalAzureAccounts = 0;
        public int TotalAzureAccounts => totalAzureAccounts;

        int unlinkedWisaAccounts = 0;
        public int UnlinkedWisaAccounts => unlinkedWisaAccounts;

        int unlinkedDirectoryAccounts = 0;
        public int UnlinkedDirectoryAccounts => unlinkedDirectoryAccounts;

        int unlinkedSmartschoolAccounts = 0;
        public int UnlinkedSmartschoolAccounts => unlinkedSmartschoolAccounts;

        int unlinkedAzureAccounts = 0;
        public int UnlinkedAzureAccounts => unlinkedAzureAccounts;

        int linkedWisaAccounts = 0;
        public int LinkedWisaAccounts => linkedWisaAccounts;

        int linkedDirectoryAccounts = 0;
        public int LinkedDirectoryAccounts => linkedDirectoryAccounts;

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
            foreach(var account in AccountApi.Directory.AccountManager.Students)
            {
                if(account.PrincipalName.Length == 0) continue;

                if(List.ContainsKey(account.PrincipalName))
                {
                    List[account.PrincipalName].Directory.Account = account;
                } else
                {
                    List.Add(account.PrincipalName, new LinkedAccount(account));
                }
            }

            var lln = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if (lln != null)
            {
                AddSmartschoolAccounts(lln);
            }

            foreach(var account in AccountApi.Wisa.Students.All)
            {
                bool linked = false;
                AccountApi.Directory.Account directoryMatch = AccountApi.Directory.AccountManager.GetStudentByWisaID(account.WisaID);

                if (directoryMatch != null && directoryMatch.PrincipalName.Length > 0)
                {
                    if (List.ContainsKey(directoryMatch.PrincipalName))
                    {
                        List[directoryMatch.Mail].Wisa.Account = account;
                        linked = true;
                    }
                    //else
                    //{
                    //    List.Add(directoryMatch.Mail, new LinkedAccount(account));
                    //    linked = true;
                    //}
                }

                if (!linked)
                {
                    var smartschoolMatch = (lln as AccountApi.Smartschool.Group).FindAccountByWisaID(account.WisaID);

                    if (smartschoolMatch != null)
                    {
                        if (List.ContainsKey(smartschoolMatch.UID))
                        {
                            List[smartschoolMatch.UID].Wisa.Account = account;
                            linked = true;
                        }
                    }
                }

                //if (!linked)
                //{
                //    var azureMatch = AccountApi.Azure.UserManager.Instance.FindAccountByWisaID(account.WisaID);
                //    if (azureMatch != null)
                //    {
                //        if (List.ContainsKey(azureMatch.UserPrincipalName))
                //        {
                //            List[azureMatch.UserPrincipalName].Wisa.Account = account;
                //            linked = true;
                //        }
                //    }
                //}

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
                        List[account.UserPrincipalName].Azure.Account = account;
                        found = true;
                    } else
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

                    //if (!found)
                    //{
                    //    List.Add(account.Id, new LinkedAccount(account));
                    //}
                }
                
            }

            // count 
            totalWisaAccounts = totalDirectoryAccounts = totalSmartschoolAccounts = totalAzureAccounts = 0;
            unlinkedWisaAccounts = unlinkedDirectoryAccounts = unlinkedSmartschoolAccounts = unlinkedAzureAccounts = 0;
            linkedWisaAccounts = linkedDirectoryAccounts = linkedSmartschoolAccounts = linkedAzureAccounts = 0;

            foreach (var group in List.Values)
            {
                if (group == null) continue;
                bool incomplete = (!group.Wisa.Exists || !group.Smartschool.Exists || !group.Directory.Exists || !group.Azure.Exists);
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
                if (group.Directory.Exists)
                {
                    totalDirectoryAccounts++;
                    if (incomplete) unlinkedDirectoryAccounts++;
                    else linkedDirectoryAccounts++;
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
            foreach(var entry in List)
            {
                if (entry.Value.Wisa.Account != null && entry.Value.Wisa.Account.WisaID == account.AccountID)
                {
                    return entry.Key;
                }

                if (entry.Value.Directory.Account != null && entry.Value.Directory.Account.WisaID == account.AccountID)
                {
                    return entry.Key;
                }
            }
            return null;
        }
    }
}

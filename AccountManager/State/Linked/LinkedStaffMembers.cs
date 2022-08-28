using AccountApi;
using AccountManager.Action.StaffAccount;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class LinkedStaffMembers
    {
        public Dictionary<string, LinkedStaffMember> List = new Dictionary<string, LinkedStaffMember>();

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
            List.Clear();
            foreach (var account in AccountApi.Directory.AccountManager.Staff)
            {
                if (account.PrincipalName.Length == 0) continue;

                bool import = true;
                foreach(var rule in App.Instance.AD.ImportRules)
                {
                    if (rule.Rule == Rule.AD_DontImportUser && rule.ShouldApply(account))
                    {
                        import = false;
                        break;
                    }
                }

                if(import)
                {
                    if (List.ContainsKey(account.PrincipalName))
                    {
                        List[account.PrincipalName].Directory.Account = account;
                    }
                    else
                    {
                        List.Add(account.PrincipalName, new LinkedStaffMember(account));
                    }
                }  
            }

            var staff = AccountApi.Smartschool.GroupManager.Root == null ? null : AccountApi.Smartschool.GroupManager.Root.Find("Personeel");
            if (staff != null)
            {
                addSmartschoolAccounts(staff);
            }

            AccountApi.Wisa.StaffManager.ApplyImportRules(App.Instance.Wisa.ImportRules.ToList());
            foreach (var account in AccountApi.Wisa.StaffManager.All)
            {
                bool linked = false;
                AccountApi.Directory.Account directoryMatch = AccountApi.Directory.AccountManager.GetStaffmemberByWisaName(account.CODE);
                
                if (directoryMatch == null) directoryMatch = AccountApi.Directory.AccountManager.GetStaffmemberByName(account.FirstName, account.LastName);

                if (directoryMatch != null)
                {
                    if (List.ContainsKey(directoryMatch.PrincipalName) && !List[directoryMatch.PrincipalName].Wisa.Exists)
                    {
                        List[directoryMatch.PrincipalName].Wisa.Account = account;
                        linked = true;
                    }
                }

                if (!linked)
                {
                    var smartschoolMatch = (staff as AccountApi.Smartschool.Group).FindAccountByWisaID(account.CODE);

                    if (smartschoolMatch != null)
                    {
                        if (List.ContainsKey(smartschoolMatch.Mail))
                        {
                            List[smartschoolMatch.Mail].Wisa.Account = account;
                            linked = true;
                        }
                    }
                }

                if (!linked)
                {
                    List.Add(account.WisaID, new LinkedStaffMember(account));
                }
            }

            foreach (var account in AccountApi.Azure.UserManager.Instance.Users)
            {
                if (account.UserPrincipalName != null)
                {
                    if (List.ContainsKey(account.UserPrincipalName))
                    {
                        List[account.UserPrincipalName].Azure.Account = account;
                    }
                    else
                    {
                        foreach (var linkedAccount in List)
                        {
                            if (linkedAccount.Value.Wisa.Account != null && linkedAccount.Value.Wisa.Account.WisaID.Equals(account.EmployeeId))
                            {
                                linkedAccount.Value.Azure.Account = account;
                                break;
                            }
                        }
                    }
                }

            }

            countAccounts();

            addActions();
        }

        private void addActions()
        {
            foreach(var account in List.Values)
            {
                StaffMemberActionParser.AddActions(account);
            }
        }

        private void countAccounts()
        {
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
        }

        private void addSmartschoolAccounts(IGroup staff)
        {
            foreach (var account in staff.Accounts)
            {
                var directoryAccount = AccountApi.Directory.AccountManager.GetStaffmemberByWisaName(account.AccountID);

                if (directoryAccount != null)
                {
                    if (List.ContainsKey(directoryAccount.PrincipalName))
                    {
                        List[directoryAccount.PrincipalName].Smartschool.Account = account as AccountApi.Smartschool.Account;
                    }
                    else
                    {
                        List.Add(directoryAccount.PrincipalName, new LinkedStaffMember(account as AccountApi.Smartschool.Account));
                    }
                }
                else if (!List.ContainsKey(account.AccountID))
                {
                    List.Add(account.AccountID, new LinkedStaffMember(account as AccountApi.Smartschool.Account));
                }
            }

            if (staff.Children != null)
                foreach (var child in staff.Children)
                {
                    addSmartschoolAccounts(child);
                }
        }
    }
}

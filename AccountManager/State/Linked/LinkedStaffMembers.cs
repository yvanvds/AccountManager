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

        int totalGoogleAccounts = 0;
        public int TotalGoogleAccounts => totalGoogleAccounts;

        int unlinkedWisaAccounts = 0;
        public int UnlinkedWisaAccounts => unlinkedWisaAccounts;

        int unlinkedDirectoryAccounts = 0;
        public int UnlinkedDirectoryAccounts => unlinkedDirectoryAccounts;

        int unlinkedSmartschoolAccounts = 0;
        public int UnlinkedSmartschoolAccounts => unlinkedSmartschoolAccounts;

        int unlinkedGoogleAccounts = 0;
        public int UnlinkedGoogleAccounts => unlinkedGoogleAccounts;

        int linkedWisaAccounts = 0;
        public int LinkedWisaAccounts => linkedWisaAccounts;

        int linkedDirectoryAccounts = 0;
        public int LinkedDirectoryAccounts => linkedDirectoryAccounts;

        int linkedSmartschoolAccounts = 0;
        public int LinkedSmartschoolAccounts => linkedSmartschoolAccounts;

        int linkedGoogleAccounts = 0;
        public int LinkedGoogleAccounts => linkedGoogleAccounts;

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
                    if (List.ContainsKey(account.UID))
                    {
                        List[account.UID].Directory.Account = account;
                    }
                    else
                    {
                        List.Add(account.UID, new LinkedStaffMember(account));
                    }
                }  
            }

            if (AccountApi.Google.AccountManager.All != null)
            foreach (var account in AccountApi.Google.AccountManager.All.Values)
            {
                if (account.IsStaff)
                {
                    if (List.ContainsKey(account.UID))
                    {
                        List[account.UID].Google.Account = account;
                    }
                    else
                    {
                        List.Add(account.UID, new LinkedStaffMember(account));
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
                AccountApi.Directory.Account match = AccountApi.Directory.AccountManager.GetStaffmemberByWisaID(account.CODE);
                if (match == null) match = AccountApi.Directory.AccountManager.GetStaffmemberByName(account.FirstName, account.LastName);

                if (match != null)
                {
                    if (List.ContainsKey(match.UID) && !List[match.UID].Wisa.Exists)
                    {
                        List[match.UID].Wisa.Account = account;
                    }
                    else
                    {
                        List.Add("WISA-" + account.CODE, new LinkedStaffMember(account));
                    }
                }
                else List.Add("WISA-" + account.CODE, new LinkedStaffMember(account));
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
            totalWisaAccounts = totalDirectoryAccounts = totalSmartschoolAccounts = totalGoogleAccounts = 0;
            unlinkedWisaAccounts = unlinkedDirectoryAccounts = unlinkedSmartschoolAccounts = unlinkedGoogleAccounts = 0;
            linkedWisaAccounts = linkedDirectoryAccounts = linkedSmartschoolAccounts = linkedGoogleAccounts = 0;

            foreach (var group in List.Values)
            {
                if (group == null) continue;
                bool incomplete = (!group.Wisa.Exists || !group.Smartschool.Exists || !group.Directory.Exists || !group.Google.Exists);
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
                if (group.Google.Exists)
                {
                    totalGoogleAccounts++;
                    if (incomplete) unlinkedGoogleAccounts++;
                    else linkedGoogleAccounts++;
                }
            }
        }

        private void addSmartschoolAccounts(IGroup staff)
        {
            foreach (var account in staff.Accounts)
            {
                if (List.ContainsKey(account.UID))
                {
                    List[account.UID].Smartschool.Account = account as AccountApi.Smartschool.Account;
                }
                else
                {
                    List.Add(account.UID, new LinkedStaffMember(account as AccountApi.Smartschool.Account));
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

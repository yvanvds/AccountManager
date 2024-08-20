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

        int totalWisaAccounts;
        public int TotalWisaAccounts => totalWisaAccounts;

        int totalSmartschoolAccounts;
        public int TotalSmartschoolAccounts => totalSmartschoolAccounts;

        int totalAzureAccounts;
        public int TotalAzureAccounts => totalAzureAccounts;

        int unlinkedWisaAccounts;
        public int UnlinkedWisaAccounts => unlinkedWisaAccounts;

        int unlinkedSmartschoolAccounts;
        public int UnlinkedSmartschoolAccounts => unlinkedSmartschoolAccounts;

        int unlinkedAzureAccounts;
        public int UnlinkedAzureAccounts => unlinkedAzureAccounts;

        int linkedWisaAccounts;
        public int LinkedWisaAccounts => linkedWisaAccounts;

        int linkedSmartschoolAccounts;
        public int LinkedSmartschoolAccounts => linkedSmartschoolAccounts;

        int linkedAzureAccounts;
        public int LinkedAzureAccounts => linkedAzureAccounts;

        public async Task ReLink()
        {
            await Task.Run(() => DoRelink()).ConfigureAwait(false);
            App.Instance.Linked.UpdateObservers();
        }

        private void DoRelink()
        {
            List.Clear();
            
            var staff = AccountApi.Smartschool.GroupManager.Root == null ? null : AccountApi.Smartschool.GroupManager.Root.Find("Personeel");
            if (staff != null)
            {
                addSmartschoolAccounts(staff);
            }

            AccountApi.Wisa.StaffManager.ApplyImportRules(App.Instance.Wisa.ImportRules.ToList());
            foreach (var account in AccountApi.Wisa.StaffManager.All)
            {
                bool linked = false;

                var smartschoolMatch = (staff as AccountApi.Smartschool.Group).FindAccountByWisaID(account.CODE);

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
        }

        private void addSmartschoolAccounts(IGroup staff)
        {
            foreach (var account in staff.Accounts)
            {
                if (!List.ContainsKey(account.Mail))
                {
                    List.Add(account.Mail, new LinkedStaffMember(account as AccountApi.Smartschool.Account));
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

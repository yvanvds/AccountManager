using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public static class LinkedAccounts
    {
        public static Dictionary<string, LinkedAccount> List = new Dictionary<string, LinkedAccount>();

        static int totalWisaAccounts = 0;
        public static int TotalWisaAccounts => totalWisaAccounts;

        static int totalDirectoryAccounts = 0;
        public static int TotalDirectoryAccounts => totalDirectoryAccounts;

        static int totalSmartschoolAccounts = 0;
        public static int TotalSmartschoolAccounts => totalSmartschoolAccounts;

        static int totalGoogleAccounts = 0;
        public static int TotalGoogleAccounts => totalGoogleAccounts;

        static int unlinkedWisaAccounts = 0;
        public static int UnlinkedWisaAccounts => unlinkedWisaAccounts;

        static int unlinkedDirectoryAccounts = 0;
        public static int UnlinkedDirectoryAccounts => unlinkedDirectoryAccounts;

        static int unlinkedSmartschoolAccounts = 0;
        public static int UnlinkedSmartschoolAccounts => unlinkedSmartschoolAccounts;

        static int unlinkedGoogleAccounts = 0;
        public static int UnlinkedGoogleAccounts => unlinkedGoogleAccounts;

        static int linkedWisaAccounts = 0;
        public static int LinkedWisaAccounts => linkedWisaAccounts;

        static int linkedDirectoryAccounts = 0;
        public static int LinkedDirectoryAccounts => linkedDirectoryAccounts;

        static int linkedSmartschoolAccounts = 0;
        public static int LinkedSmartschoolAccounts => linkedSmartschoolAccounts;

        static int linkedGoogleAccounts = 0;
        public static int LinkedGoogleAccounts => linkedGoogleAccounts;

        public static Task ReLink()
        {
            return Task.Run(() => DoRelink());
        }

        private static void DoRelink()
        {
            //if (!Data.Instance.ConfigReady) return;
            if (AccountApi.Smartschool.GroupManager.Root == null) return;

            List.Clear();
            foreach(var account in AccountApi.Directory.AccountManager.Students)
            {
                if(List.ContainsKey(account.UID))
                {
                    List[account.UID].directoryAccount = account;
                } else
                {
                    List.Add(account.UID, new LinkedAccount(account));
                }
            }

            foreach(var account in AccountApi.Google.AccountManager.All.Values)
            {
                if(!account.IsStaff)
                {
                    if(List.ContainsKey(account.UID))
                    {
                        List[account.UID].googleAccount = account;
                    } else
                    {
                        List.Add(account.UID, new LinkedAccount(account));
                    }
                }
            }

            var lln = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if(lln != null)
            {
                AddSmartschoolAccounts(lln);
            }

            foreach(var account in AccountApi.Wisa.Students.All)
            {
                AccountApi.Directory.Account match = AccountApi.Directory.AccountManager.GetStudentByWisaID(account.WisaID);
                if(match != null)
                {
                    if (List.ContainsKey(match.UID))
                    {
                        List[match.UID].wisaAccount = account;
                    }
                    else
                    {
                        List.Add(match.UID, new LinkedAccount(account));
                    }
                } else
                {
                    List.Add(account.WisaID, new LinkedAccount(account));
                }
            }

            // count 
            totalWisaAccounts = totalDirectoryAccounts = totalSmartschoolAccounts = totalGoogleAccounts = 0;
            unlinkedWisaAccounts = unlinkedDirectoryAccounts = unlinkedSmartschoolAccounts = unlinkedGoogleAccounts = 0;
            linkedWisaAccounts = linkedDirectoryAccounts = linkedSmartschoolAccounts = linkedGoogleAccounts = 0;

            foreach (var group in List.Values)
            {
                if (group == null) continue;
                bool incomplete = (group.wisaAccount == null || group.smartschoolAccount == null || group.directoryAccount == null);
                if (group.wisaAccount != null)
                {
                    totalWisaAccounts++;
                    if (incomplete) unlinkedWisaAccounts++;
                    else linkedWisaAccounts++;
                }
                if (group.smartschoolAccount != null)
                {
                    totalSmartschoolAccounts++;
                    if (incomplete) unlinkedSmartschoolAccounts++;
                    else linkedSmartschoolAccounts++;
                }
                if (group.directoryAccount != null)
                {
                    totalDirectoryAccounts++;
                    if (incomplete) unlinkedDirectoryAccounts++;
                    else linkedDirectoryAccounts++;
                }
                if (group.googleAccount != null)
                {
                    totalGoogleAccounts++;
                    if (incomplete) unlinkedGoogleAccounts++;
                    else linkedGoogleAccounts++;
                }
            }

            // add actions
            foreach (var account in List.Values)
            {
                account.Compare();
            }
        }

        private static void AddSmartschoolAccounts(AccountApi.IGroup group)
        {
            foreach(var account in group.Accounts)
            {
                if(List.ContainsKey(account.UID))
                {
                    List[account.UID].smartschoolAccount = account as AccountApi.Smartschool.Account;
                } else
                {
                    List.Add(account.UID, new LinkedAccount(account as AccountApi.Smartschool.Account));
                }
            }

            if(group.Children != null)
            foreach(var child in group.Children)
            {
                AddSmartschoolAccounts(child);
            }
        }
    }
}

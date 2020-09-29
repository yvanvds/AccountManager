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
            //if (!Data.Instance.ConfigReady) return;
            if (AccountApi.Smartschool.GroupManager.Root == null) return;

            List.Clear();
            foreach(var account in AccountApi.Directory.AccountManager.Students)
            {

                if(List.ContainsKey(account.UID))
                {
                    List[account.UID].Directory.Account = account;
                } else
                {
                    List.Add(account.UID, new LinkedAccount(account));
                }
            }

            //foreach(var account in AccountApi.Google.AccountManager.All.Values)
            //{
            //    if(!account.IsStaff)
            //    {
            //        if(List.ContainsKey(account.UID))
            //        {
            //            List[account.UID].Google.Account = account;
            //        } else
            //        {
            //            List.Add(account.UID, new LinkedAccount(account));
            //        }
            //    }
            //}

            var lln = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if(lln != null)
            {
                AddSmartschoolAccounts(lln);
            }

            foreach(var account in AccountApi.Wisa.Students.All)
            {
                bool linked = false;
                AccountApi.Directory.Account directoryMatch = AccountApi.Directory.AccountManager.GetStudentByWisaID(account.WisaID);

                if (directoryMatch != null)
                {
                    if (List.ContainsKey(directoryMatch.UID))
                    {
                        List[directoryMatch.UID].Wisa.Account = account;
                        linked = true;
                    }
                    else
                    {
                        List.Add(directoryMatch.UID, new LinkedAccount(account));
                        linked = true;
                    }
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

                if (!linked)
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
                bool incomplete = (!group.Wisa.Exists || !group.Smartschool.Exists || !group.Directory.Exists);
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
                //if (group.Google.Exists)
                //{
                //    totalGoogleAccounts++;
                //    if (incomplete) unlinkedGoogleAccounts++;
                //    else linkedGoogleAccounts++;
                //}
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
                if(List.ContainsKey(account.UID))
                {
                    List[account.UID].Smartschool.Account = account as AccountApi.Smartschool.Account;
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

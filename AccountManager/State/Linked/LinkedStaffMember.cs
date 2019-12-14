using AccountManager.Action.StaffAccount;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class LinkedStaffMember
    {
        public AccountStatus<AccountApi.Wisa.Staff> Wisa { get; } = new AccountStatus<AccountApi.Wisa.Staff>();
        public AccountStatus<AccountApi.Directory.Account> Directory { get; } = new AccountStatus<AccountApi.Directory.Account>();
        public AccountStatus<AccountApi.Smartschool.Account> Smartschool { get; } = new AccountStatus<AccountApi.Smartschool.Account>();
        public AccountStatus<AccountApi.Google.Account> Google { get; } = new AccountStatus<AccountApi.Google.Account>();

        public List<AccountAction> Actions = new List<AccountAction>();

        public LinkedStaffMember(AccountApi.Wisa.Staff account)
        {
            Wisa.Account = account;
        }

        public LinkedStaffMember(AccountApi.Directory.Account account)
        {
            Directory.Account = account;
        }

        public LinkedStaffMember(AccountApi.Smartschool.Account account)
        {
            Smartschool.Account = account;
        }

        public LinkedStaffMember(AccountApi.Google.Account account)
        {
            Google.Account = account;
        }

        public string UID
        {
            get
            {
                if (Directory.Account != null) return Directory.Account.UID;
                if (Smartschool.Account != null) return Smartschool.Account.UID;
                if (Google.Account != null) return Google.Account.UID;
                if (Wisa.Account != null) return Wisa.Account.CODE;
                return "No User ID";
            }
        }

        public string Name
        {
            get
            {
                if (Wisa.Account != null) return Wisa.Account.FirstName + " " + Wisa.Account.LastName;
                if (Smartschool.Account != null) return Smartschool.Account.GivenName + " " + Smartschool.Account.SurName;
                if (Directory.Account != null) return Directory.Account.FullName;
                if (Google.Account != null) return Google.Account.FullName;
                return "No User Name";
            }
        }

        public bool OK { get; set; }

        public void SetBasicFlags()
        {
            Wisa.SetFlag();
            Smartschool.SetFlag();
            Directory.SetFlag();
            Google.SetFlag();
        }

        public AccountAction GetSameAction(AccountAction action)
        {
            foreach (var act in Actions)
            {
                if (act.GetType().Name == action?.GetType().Name)
                {
                    return act;
                }
            }
            return null;
        }
    }
}

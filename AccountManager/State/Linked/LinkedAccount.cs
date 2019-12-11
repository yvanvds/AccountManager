using AccountManager.Action.Account;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class LinkedAccount
    {
        public AccountStatus<AccountApi.Wisa.Student> Wisa { get; } = new AccountStatus<AccountApi.Wisa.Student>();
        public AccountStatus<AccountApi.Directory.Account> Directory { get; } = new AccountStatus<AccountApi.Directory.Account>();
        public AccountStatus<AccountApi.Smartschool.Account> Smartschool { get; } = new AccountStatus<AccountApi.Smartschool.Account>();
        public AccountStatus<AccountApi.Google.Account> Google { get; } = new AccountStatus<AccountApi.Google.Account>();

        public List<AccountAction> Actions = new List<AccountAction>();

        public LinkedAccount(AccountApi.Wisa.Student account)
        {
            Wisa.Account = account;
        }

        public LinkedAccount(AccountApi.Directory.Account account)
        {
            Directory.Account = account;
        }

        public LinkedAccount(AccountApi.Smartschool.Account account)
        {
            Smartschool.Account = account;
        }

        public LinkedAccount(AccountApi.Google.Account account)
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
                if (Wisa.Account != null) return Wisa.Account.WisaID;
                return "No User ID";
            }
        }

        public string Name
        {
            get
            {
                if (Wisa.Account != null) return Wisa.Account.Name + " " + Wisa.Account.FirstName;
                if (Smartschool.Account != null) return Smartschool.Account.SurName + " " + Smartschool.Account.GivenName;
                if (Directory.Account != null) return Directory.Account.FullName;
                if (Google.Account != null) return Google.Account.FullName;
                return "No User Name";
            }
        }

        public string ClassGroup
        {
            get
            {
                if (Wisa.Account != null) return Wisa.Account.ClassGroup;
                if (Directory.Account != null) return Directory.Account.ClassGroup;
                if (Smartschool.Account != null) return Smartschool.Account.Group;
                return "Google";
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
            foreach(var act in Actions)
            {
                if(act.GetType().Name == action?.GetType().Name)
                {
                    return act;
                }
            }
            return null;
        }

    }
}

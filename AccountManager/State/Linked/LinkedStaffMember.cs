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
        public AccountStatus<AccountApi.Smartschool.Account> Smartschool { get; } = new AccountStatus<AccountApi.Smartschool.Account>();
        public AccountStatus<AccountApi.Azure.User> Azure { get; } = new AccountStatus<AccountApi.Azure.User>();

        public List<AccountAction> Actions = new List<AccountAction>();

        public LinkedStaffMember(AccountApi.Wisa.Staff account)
        {
            Wisa.Account = account;
        }


        public LinkedStaffMember(AccountApi.Smartschool.Account account)
        {
            Smartschool.Account = account;
        }

        public LinkedStaffMember(AccountApi.Azure.User account)
        {
            Azure.Account = account;
        }

        public string UID
        {
            get
            {
                if (Smartschool.Account != null) return Smartschool.Account.UID;
                if (Azure.Account != null) return Azure.Account.EmployeeId;
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
                if (Azure.Account != null) return Azure.Account.DisplayName;
                return "No User Name";
            }
        }

        public string Mail
        {
            get
            {
                if (Smartschool.Account != null) return Smartschool.Account.Mail;
                if (Azure.Account != null) return Azure.Account.UserPrincipalName;
                return "No Mail";
            }
        }

        public bool OK { get; set; }

        public void SetBasicFlags()
        {
            Wisa.SetFlag();
            Smartschool.SetFlag();
            Azure.SetFlag();
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

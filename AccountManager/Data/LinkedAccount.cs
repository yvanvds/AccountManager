using AccountManager.Action;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public class LinkedAccount
    {
        public AccountApi.Wisa.Student wisaAccount = null;
        public AccountApi.Directory.Account directoryAccount = null;
        public AccountApi.Smartschool.Account smartschoolAccount = null;
        public AccountApi.Google.Account googleAccount = null;

        public List<AccountAction> Actions = new List<AccountAction>();

        public LinkedAccount(AccountApi.Wisa.Student account)
        {
            wisaAccount = account;
        }

        public LinkedAccount(AccountApi.Directory.Account account)
        {
            directoryAccount = account;
        }

        public LinkedAccount(AccountApi.Smartschool.Account account)
        {
            smartschoolAccount = account;
        }

        public LinkedAccount(AccountApi.Google.Account account)
        {
            googleAccount = account;
        }

        public string UID
        {
            get
            {
                if (directoryAccount != null) return directoryAccount.UID;
                if (smartschoolAccount != null) return smartschoolAccount.UID;
                if (googleAccount != null) return googleAccount.UID;
                if (wisaAccount != null) return wisaAccount.WisaID;
                return "No User ID";
            }
        }

        public string Name
        {
            get
            {
                if (wisaAccount != null) return wisaAccount.Name + " " + wisaAccount.FirstName;
                if (smartschoolAccount != null) return smartschoolAccount.SurName + " " + smartschoolAccount.GivenName;
                if (directoryAccount != null) return directoryAccount.FullName;
                if (googleAccount != null) return googleAccount.FullName;
                return "No User Name";
            }
        }

        public string ClassGroup
        {
            get
            {
                if (wisaAccount != null) return wisaAccount.ClassGroup;
                if (directoryAccount != null) return directoryAccount.ClassGroup;
                if (smartschoolAccount != null) return smartschoolAccount.Group;
                return "Google";
            }
        }

        private bool accountOK;
        public bool AccountOK => accountOK;

        public void Compare()
        {
            accountOK = false;

            if (wisaAccount == null)
            {
                wisaStatusIcon = "AlertCircleOutline";
                wisaStatusColor = "DarkRed";
            }
            else
            {
                wisaStatusIcon = "CheckboxMarkedCircleOutline";
                wisaStatusColor = "DarkGreen";
            }

            if (smartschoolAccount == null)
            {
                smartschoolStatusIcon = "AlertCircleOutline";
                smartschoolStatusColor = "DarkRed";
            }
            else
            {
                smartschoolStatusIcon = "CheckboxMarkedCircleOutline";
                smartschoolStatusColor = "DarkGreen";
            }

            if (directoryAccount == null)
            {
                directoryStatusIcon = "AlertCircleOutline";
                directoryStatusColor = "DarkRed";
            }
            else
            {
                directoryStatusIcon = "CheckboxMarkedCircleOutline";
                directoryStatusColor = "DarkGreen";
            }

            if (googleAccount == null)
            {
                googleStatusIcon = "AlertCircleOutline";
                googleStatusColor = "DarkRed";
            }
            else
            {
                googleStatusIcon = "CheckboxMarkedCircleOutline";
                googleStatusColor = "DarkGreen";
            }

            

            if (wisaAccount != null && directoryAccount != null && smartschoolAccount != null)// don't include google anymore && googleAccount != null)
            {
                accountOK = true;
            } else
            {
                FindActionsForMissingAccounts();
                accountOK = false;
            }
        }

        private void FindActionsForMissingAccounts()
        {
            // if account is only on google, suggest removal
            if (wisaAccount == null && directoryAccount == null && smartschoolAccount == null && googleAccount != null)
            {
                Actions.Add(new RemoveAccountFromGoogle());
            }

            // if account is only on directory, suggest removal
            else if (wisaAccount == null && directoryAccount != null && smartschoolAccount == null)
            {
                Actions.Add(new RemoveAccountFromDirectory());
            }
        }

        public bool WisaLinked => wisaAccount != null;
        public bool SmartschoolLinked => smartschoolAccount != null;
        public bool DirectoryLinked => directoryAccount != null;
        public bool GoogleLinked => googleAccount != null;

        private string wisaStatusIcon;
        public string WisaStatusIcon => wisaStatusIcon;

        private string wisaStatusColor;
        public string WisaStatusColor => wisaStatusColor;

        private string directoryStatusIcon;
        public string DirectoryStatusIcon => directoryStatusIcon;

        private string directoryStatusColor;
        public string DirectoryStatusColor => directoryStatusColor;

        private string smartschoolStatusIcon;
        public string SmartschoolStatusIcon => smartschoolStatusIcon;

        private string smartschoolStatusColor;
        public string SmartschoolStatusColor => smartschoolStatusColor;

        private string googleStatusIcon;
        public string GoogleStatusIcon => googleStatusIcon;

        private string googleStatusColor;
        public string GoogleStatusColor => googleStatusColor;
    }
}

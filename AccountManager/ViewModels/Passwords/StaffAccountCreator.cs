using AccountApi;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Input;

namespace AccountManager.ViewModels.Passwords
{
    public class StaffAccountCreator : INotifyPropertyChanged
    {
        public ICommand ClearCommand { get; private set; }
        public IAsyncCommand CreateCommand { get; private set; }
        public IAsyncCommand PrintCommand { get; private set; }

        public StaffAccountCreator()
        {
            ClearCommand = new RelayCommand(Clear);
            CreateCommand = new RelayAsyncCommand(Create);
            PrintCommand = new RelayAsyncCommand(Print);
            Clear();
        }

        private async Task Print()
        {
            await Exporters.PasswordManager.Instance.Accounts
                .ExportStaffPasswordToPDF(account.FullName, UID, account.Mail, CopyCode.ToString(), NetworkPassword, SmartschoolPassword)
                .ConfigureAwait(false);
        }

        private AccountApi.Directory.Account account;

        private async Task Create()
        {
            CreateIndicator = true;
            account = await AccountApi.Directory.AccountManager.Create(
                FirstName, LastName, "", "", getRole()).ConfigureAwait(false);

            if (account != null)
            {
                UID = account.UID;
                CopyCode = getCopyCode();
                account.CopyCode = CopyCode;

                NetworkPassword = Password.Create();
                account.SetPassword(NetworkPassword);

                MainWindow.Instance.Log.AddMessage(Origin.Directory, "Added account for " + account.FullName);
                await createSmartschoolAccount(account).ConfigureAwait(false);
                //await createGoogleAccount(account).ConfigureAwait(false);

                PrintEnabled = true;
            }
            CreateIndicator = false;
            State.App.Instance.AD.UpdateObservers();
        }

        public void Clear()
        {
            FirstName = "";
            LastName = "";
            UID = "";
            RoleIndex = -1;
            Gender = 0.5f;
            NetworkPassword = "";
            SmartschoolPassword = "";
            CopyCode = 0;
            
            PrintEnabled = false;
        }

        #region functions

        private AccountRole getRole()
        {
            switch (RoleIndex)
            {
                case 0: return AccountRole.Teacher;
                case 1: return AccountRole.Support;
                case 2: return AccountRole.IT;
                case 3: return AccountRole.Director;
                default: return AccountRole.Other;
            }
        }

        private GenderType getGender()
        {
            if (Gender > 5) return GenderType.Male;
            else return GenderType.Female;
        }

        private int getCopyCode()
        {
            var random = new Random();
            bool valid = false;
            int code = 0;
            while (!valid)
            {
                code = random.Next(1001, 9999);
                valid = true;
                foreach (var account in AccountApi.Directory.AccountManager.Staff)
                {
                    if (code == account.CopyCode) valid = false;
                }
            }
            return code;
        }

        private async Task createSmartschoolAccount(AccountApi.Directory.Account account)
        {
            var smartschoolAccount = new AccountApi.Smartschool.Account();
            SmartschoolPassword = AccountApi.Password.Create();

            smartschoolAccount.UID = UID;
            smartschoolAccount.Role = getRole();
            smartschoolAccount.GivenName = FirstName;
            smartschoolAccount.SurName = LastName;
            smartschoolAccount.AccountID = UID;
            smartschoolAccount.Gender = getGender();

            smartschoolAccount.Mail = UID + "@" + AccountApi.Directory.Connector.AzureDomain;

            var result = await AccountApi.Smartschool.AccountManager
                .Save(smartschoolAccount, SmartschoolPassword)
                .ConfigureAwait(false);

            if (!result)
            {
                MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to add " + account.FullName);
                return;
            }
            else
            {
                MainWindow.Instance.Log.AddMessage(Origin.Smartschool, "Added account for " + account.FullName);

                IGroup group = null;
                switch(smartschoolAccount.Role)
                {
                    case AccountRole.Teacher: group = AccountApi.Smartschool.GroupManager.Root.Find("Leerkrachten"); break;
                    case AccountRole.Director: group = AccountApi.Smartschool.GroupManager.Root.Find("Directie"); break;
                    case AccountRole.IT: group = AccountApi.Smartschool.GroupManager.Root.Find("Leerkrachten"); break;
                    case AccountRole.Maintenance: group = AccountApi.Smartschool.GroupManager.Root.Find("Onderhoudspersoneel"); break;
                    case AccountRole.Support: group = AccountApi.Smartschool.GroupManager.Root.Find("Secretariaat"); break;
                    default: group = AccountApi.Smartschool.GroupManager.Root.Find("Personeel"); break;
                }

                var groupResult = await AccountApi.Smartschool.GroupManager.AddUserToGroup(smartschoolAccount, group).ConfigureAwait(false);
                if (!groupResult)
                {
                    MainWindow.Instance.Log.AddError(Origin.Smartschool, "Failed to add " + account.FullName + " to group " + group.Name);
                }
            }
        }

        //private async Task createGoogleAccount(AccountApi.Directory.Account account)
        //{
        //    var googleAccount = new AccountApi.Google.Account();
        //    googleAccount.GivenName = FirstName;
        //    googleAccount.FamilyName = LastName;
        //    googleAccount.IsStaff = true;
        //    googleAccount.UID = UID;

        //    bool result = await AccountApi.Google.AccountManager.Add(googleAccount, NetworkPassword).ConfigureAwait(false);
        //    if (!result)
        //    {
        //        MainWindow.Instance.Log.AddError(Origin.Google, "Failed to add " + account.FullName);
        //        return;
        //    }
        //    else
        //    {
        //        MainWindow.Instance.Log.AddMessage(Origin.Google, "Added account for " + account.FullName);
        //    }
        //}
        #endregion

        #region Properties
        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        private string firstName;
        public string FirstName
        {
            get => firstName;
            set
            {
                firstName = value.Trim();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(FirstName)));
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(CreateEnabled)));
            }
        }

        private string lastName;
        public string LastName
        {
            get => lastName;
            set
            {
                lastName = value.Trim();
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(LastName)));
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(CreateEnabled)));
            }
        }

        private string uid;
        public string UID
        {
            get => uid;
            set
            {
                uid = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(UID)));
            }
        }

        private int copyCode = 0;
        public int CopyCode
        {
            get => copyCode;
            set
            {
                copyCode = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(CopyCode)));
            }
        }

        private int roleIndex = -1;
        public int RoleIndex
        {
            get => roleIndex;
            set
            {
                roleIndex = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(RoleIndex)));
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(CreateEnabled)));
            }
        }

        private float gender = 5.0f;
        public float Gender
        {
            get => gender;
            set
            {
                gender = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Gender)));
            }
        }

        private string networkPassword;
        public string NetworkPassword
        {
            get => networkPassword;
            set
            {
                networkPassword = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(NetworkPassword)));
            }
        }

        private string smartschoolPassword;
        public string SmartschoolPassword
        {
            get => smartschoolPassword;
            set
            {
                smartschoolPassword = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SmartschoolPassword)));
            }
        }


        public bool CreateEnabled
        {
            get => FirstName.Length > 0 && LastName.Length > 0 && RoleIndex >= 0;
        }

        bool printEnabled = false;
        public bool PrintEnabled
        {
            get => printEnabled;
            set
            {
                printEnabled = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(PrintEnabled)));
            }
        }

        private bool createIndicator = false;
        public bool CreateIndicator
        {
            get => createIndicator;
            set
            {
                createIndicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(CreateIndicator)));
            }
        }

        private bool printIndicator = false;
        public bool PrintIndicator
        {
            get => printIndicator;
            set
            {
                printIndicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(PrintIndicator)));
            }
        }

        #endregion
    }
}

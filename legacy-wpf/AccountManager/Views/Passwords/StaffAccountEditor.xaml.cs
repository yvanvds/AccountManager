using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;

namespace AccountManager.Views.Passwords
{
    /// <summary>
    /// Interaction logic for StaffAccountEditor.xaml
    /// </summary>
    public partial class StaffAccountEditor : UserControl
    {
        public static readonly DependencyProperty AccountProperty =
            DependencyProperty.Register("Account", typeof(AccountApi.Smartschool.Account), typeof(StaffAccountEditor));
        public AccountApi.Smartschool.Account Account
        {
            get { return (AccountApi.Smartschool.Account)this.GetValue(AccountProperty); }
            set { 
                this.SetValue(AccountProperty, value); 
                if (model != null)
                {
                    model.SetAccount(value);
                }
            }
        }

        ViewModels.Passwords.StaffAccountEditor model;

        public StaffAccountEditor()
        {
            InitializeComponent();
            model = new ViewModels.Passwords.StaffAccountEditor(Account);
            DataContext = model;
        }
    }
}

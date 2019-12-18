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
    /// Interaction logic for StaffAccountCreator.xaml
    /// </summary>
    public partial class StaffAccountCreator : UserControl
    {
        public ViewModels.Passwords.StaffAccountCreator Model { get; private set; }
        public StaffAccountCreator()
        {
            InitializeComponent();
            Model = new ViewModels.Passwords.StaffAccountCreator();
            DataContext = Model;
        }
    }
}

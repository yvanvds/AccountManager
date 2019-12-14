using AccountApi;
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
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.Views.Dialogs
{
    /// <summary>
    /// Interaction logic for AD_DontImportUser.xaml
    /// </summary>
    public partial class AD_DontImportUser : UserControl, IRuleEditor
    {
        public IRule Rule { get; set; }
        public Prop<string> AccountName { get; set; } = new Prop<string> { Value = "" };
        public AD_DontImportUser(IRule rule)
        {
            InitializeComponent();
            Rule = rule;
            DataContext = this;
            AccountName.Value = rule.GetConfig(0);
        }

        private void AcceptButton_Click(object sender, RoutedEventArgs e)
        {
            Rule.SetConfig(0, AccountName.Value.Trim());
        }
    }
}

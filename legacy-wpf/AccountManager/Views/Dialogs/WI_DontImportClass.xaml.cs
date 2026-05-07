using AbstractAccountApi;
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
    /// Interaction logic for WI_DontImportClass.xaml
    /// </summary>
    public partial class WI_DontImportClass : UserControl, IRuleEditor
    {
        public IRule Rule { get; set; }
        public Prop<string> ClassName { get; set; } = new Prop<string> { Value = "" };

        public WI_DontImportClass(IRule rule)
        {
            InitializeComponent();
            Rule = rule;
            DataContext = this;
            ClassName.Value = rule.GetConfig(0);
        }

        private void AcceptButton_Click(object sender, RoutedEventArgs e)
        {
            Rule.SetConfig(0, ClassName.Value.Trim());
        }
    }
}
